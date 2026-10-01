defmodule Arbiter.Accounts.Concurrency do
  @moduledoc """
  P8 (`docs/provider-account-design.md` §4.2–§4.4). **The account owns the
  ceiling; the workspace owns a cap on its use of that ceiling.**

      effective_cap(workspace) = min(
          workspace_max,
          system_max,
          account_headroom(account, workspace),
          quota_headroom(account)
      )

      account_headroom(a, ws) =
          max(0, min(a.max_concurrent, share(ws, a)) - live_count(a))

  ## Why this module exists at all

  Before P8 the account-facing ceiling was `dispatchers × workspaces ×
  max_concurrent` (§4.1): several dispatchers in one workspace at
  `max_concurrent: 4` already permitted 8 workers on one account, and
  `system_max` — the only thing above them — knows nothing about accounts.
  Any per-dispatcher tally reproduces that bug, so `live_count/1` is derived
  from `Arbiter.Worker.Registry` and nothing else.

  ## `live_count/1` is registry-derived, and that is the design

  It counts *processes*, via `Arbiter.Worker.Registry.live_dispatches/0`:
  workers currently registered whose workspace points at account `a` for the
  provider they were dispatched with. There is no counter to increment, so
  there is nothing to decrement — a worker that crashes, is killed, or exits
  without running `terminate/2` releases its slot the moment it dies. That is
  the same crash-safety the scheduler's other state has (rebuilt from live
  processes, never remembered).

  Note that `live_count/1` is account-wide even in the `share` term — a
  sibling workspace's live workers do eat into this workspace's headroom.
  That is §4.2's formula as written, and it follows from §4.3: the share is a
  cap on a *shared* ceiling, first-come-first-served between workspaces, not a
  reservation of slots held open for a quiet workspace.

  ## Which runs count toward the cap (bd-35gvrj)

  Occupancy is **every `Arbiter.Worker` process registered**, whatever the
  role — each one stamps `put_dispatch/3` in `init/1`, so there is no path to
  forget:

    * the implementer, fresh from `Dispatch.dispatch/2` (Autopilot, the
      DispatchQueue, `arb dispatch`);
    * a **resumed** implementer — the boot reconciler's mid-flight resume,
      `arb worker resume`, a Watchdog auto-resume (all `Dispatch.resume/2`);
    * fix passes and merge-queue conflict-resolution passes (their own
      `<task>:fixpass` / `<task>:conflict` registry keys);
    * ReviewGate reviewer workers (`<task>#review…` keys), counted against the
      provider they were dispatched with.

  **One ticket's agent counts once (bd-dp0p58).** During a ReviewGate fix round
  the primary worker is parked with no agent while its sub-worker runs. A
  primary with a live sub-worker (`owned_by?/2`) is therefore *not* counted;
  the sub-workers are. Truly concurrent agents still count individually —
  separate tickets always do, and a ticket's reviewer and fix pass running at
  the same time count as 2, since each is a real provider process. A primary
  with no live sub-worker counts as 1.

  Not counted, because they are not workers in the registry: an external PR
  review (`Arbiter.Reviews.ExternalReview`), a ReviewPatrol re-review or
  author reply, and the operator's own interactive sessions.

  Also counted: a dispatch **admitted** onto the account whose worker does not
  count yet (`Arbiter.Accounts.Admission`, bd-8suxac). Once its worker has
  stamped its dispatch context under the task id (in `Worker.init/1`, after
  its name registers), the worker is what counts.

  ## Who is refused at the cap (bd-8suxac)

  Counting is not enforcing. The board's plan enforces the cap for Autopilot;
  every other fresh admission through `Dispatch.dispatch/2` — `arb dispatch`,
  MCP `worker_dispatch`, the dashboard, a PRPatrol follow-up, a DispatchQueue
  replay, and Autopilot's own dispatch once more — passes
  `Arbiter.Accounts.Admission.admit/3`, which refuses it with no headroom left
  unless it is explicitly overridden (recorded). A PRPatrol follow-up that is
  refused waits in Ready for Autopilot. Resumes and a ticket's follow-up roles
  are counted but never refused (below).

  Three things keep that count from under-reading when the registry is briefly
  incomplete, which is the only way the cap can be overshot by a dispatch:

    * **Boot.** The registry starts empty, and the reconciler re-fills it one
      resume at a time. `Arbiter.Boot.ResumeGate` keeps Autopilot from
      planning until that sweep returns.
    * **A resume in flight.** `Dispatch.resume/2` stops the prior worker
      before the new one registers. Autopilot does not plan while any
      dispatch/resume is pending (`Arbiter.Board.Drain.dispatch_pending?/0`).
    * **A fresh dispatch in flight.** Its admission reserves the slot until
      its worker counts in its place, and admissions on one account serialize, so
      a burst of them can take no more than the headroom.

  ## Resumes are never refused by the cap

  A resume of an `:active` ticket passes `Arbiter.Worker.ResumeSlot` uncapped
  (stranding work is worse than overshooting), so resumes alone can exceed
  `max_concurrent` — the operator lowered it while workers ran, say. They
  still resume; `account_headroom/3` is then `0` (it floors at zero, never
  negative), and `Arbiter.Board.Autopilot` dispatches nothing new until
  occupancy drops below the cap again.

  ## Both terms are opt-in, and `nil` means "no constraint"

  `max_concurrent` migrates to `nil` (§4.4) and `share` has never been
  populated by anything but an explicit `arb account attach --share N`. With
  both `nil` the headroom is `:unlimited` and dispatch behaves exactly as it
  did before P8, bit-for-bit. When only one is set, that one bounds: `min/2`
  over an absent constraint is the present one.
  """

  require Ash.Query

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @type headroom :: non_neg_integer() | :unlimited

  @doc """
  How many workers are live on `account` right now — the one authoritative
  counter (§4.2). Derived from `Arbiter.Worker.Registry`, never stored.

  A worker that recorded no provider at dispatch counts against its
  workspace's default provider (`Arbiter.Quota.default_provider/1`), which is
  the same assumption the board scheduler's quota clamp already makes for a
  workspace's dispatches.
  """
  @spec live_count(ProviderAccount.t() | String.t() | nil) :: non_neg_integer()
  def live_count(account), do: live_count(account, [])

  @doc """
  `live_count/1`, with `exclude_task: task_id` leaving out every worker
  `task_id` owns (`Arbiter.Worker.Registry.owned_by?/2`) — for a caller
  routing one of that task's own follow-up roles, which replaces the task's
  in-flight work on the account rather than adding to it.
  """
  @spec live_count(ProviderAccount.t() | String.t() | nil, keyword()) :: non_neg_integer()
  def live_count(%ProviderAccount{} = account, opts), do: account |> holders(opts) |> length()

  def live_count(account_id, opts) when is_binary(account_id),
    do: account_id |> Resolver.get() |> live_count(opts)

  def live_count(_, _opts), do: 0

  @doc """
  The registry keys `live_count/2` counts on `account`: each live worker and
  each admitted dispatch whose worker does not count yet
  (`Arbiter.Accounts.Admission`). A refusal names them.
  """
  @spec holders(ProviderAccount.t(), keyword()) :: [String.t()]
  def holders(%ProviderAccount{id: id, provider: provider}, opts \\ []) do
    case linked_workspace_ids(id) do
      workspace_ids when map_size(workspace_ids) == 0 ->
        []

      workspace_ids ->
        code = Atom.to_string(provider)
        exclude = Keyword.get(opts, :exclude_task)

        occupants()
        |> Enum.filter(&Map.has_key?(workspace_ids, &1.workspace_id))
        |> Enum.reject(
          &(is_binary(exclude) and WorkerRegistry.owned_by?(&1.registry_key, exclude))
        )
        |> filter_matching(code)
        |> Enum.map(& &1.registry_key)
    end
  rescue
    # A ceiling that cannot be read must not stop dispatch: an unreadable
    # count reads as "nothing is running", which leaves the headroom at its
    # maximum rather than holding the fleet.
    _ -> []
  end

  @doc """
  `live_count/1` narrowed to one workspace: the live workers *this* workspace
  is contributing to its account's count, for `provider`.

  Not part of §4.2's formula — the ceiling is account-wide and deliberately
  blind to which workspace is using it. This is what a caller that subtracts
  its own in-flight work from an absolute cap needs to hand `clamp/3`.
  """
  @spec workspace_live_count(String.t() | nil, atom() | String.t() | nil) :: non_neg_integer()
  def workspace_live_count(workspace_id, provider) when is_binary(workspace_id) do
    case Arbiter.Quota.provider_code(provider) do
      nil ->
        0

      code ->
        occupants()
        |> Enum.filter(&(&1.workspace_id == workspace_id))
        |> filter_matching(code)
        |> length()
    end
  rescue
    _ -> 0
  end

  def workspace_live_count(_workspace_id, _provider), do: 0

  @doc """
  `max(0, min(a.max_concurrent, share(ws, a)) - live_count(a))` — §4.2,
  verbatim — or `:unlimited` when neither term is set (§4.4's default) and
  when there is no account to bound at all.

  `workspace` may be a `Arbiter.Tasks.Workspace` or a workspace id.
  `opts` are `live_count/2`'s (`:exclude_task`).
  """
  @spec account_headroom(ProviderAccount.t() | nil, Workspace.t() | String.t() | nil, keyword()) ::
          headroom()
  def account_headroom(account, workspace, opts \\ [])

  def account_headroom(nil, _workspace, _opts), do: :unlimited

  def account_headroom(%ProviderAccount{} = account, workspace, opts) do
    case limit(account, workspace) do
      nil -> :unlimited
      limit -> max(0, limit - live_count(account, opts))
    end
  rescue
    _ -> :unlimited
  end

  @doc """
  `min(a.max_concurrent, share(ws, a))` — the ceiling `account_headroom/3`
  subtracts the live count from — or `nil` when neither term is set.
  """
  @spec limit(ProviderAccount.t(), Workspace.t() | String.t() | nil) :: non_neg_integer() | nil
  def limit(%ProviderAccount{} = account, workspace) do
    ceiling(account.max_concurrent, Resolver.share(workspace_id(workspace), account.provider))
  end

  @doc """
  `account_headroom/2` for the account `workspace_id` is metered under for
  `provider`. `:unlimited` when the workspace is linked to no account — a
  pure read, so an unlinked workspace is never provisioned one just to be
  told it has no ceiling.
  """
  @spec headroom(String.t() | nil, atom() | String.t() | nil) :: headroom()
  def headroom(workspace_id, provider) do
    workspace_id
    |> Resolver.account(provider)
    |> account_headroom(workspace_id)
  end

  @doc """
  Fold a headroom into a caller's own absolute cap.

  `account_headroom/2` answers "how many *more*"; `base` is an absolute
  ceiling that the caller will itself subtract its in-flight work from
  (`Board.Snapshot`: `slots_total - running`). Adding those `already_counted`
  workers back converts the headroom into the caller's frame, so the account
  term bites exactly once. Folding a headroom straight into `min/2` instead
  would subtract the caller's own live workers twice and silently strangle a
  workspace to roughly half the ceiling the operator configured.
  """
  @spec clamp(non_neg_integer(), headroom(), non_neg_integer()) :: non_neg_integer()
  def clamp(base, :unlimited, _already_counted), do: base

  def clamp(base, headroom, already_counted)
      when is_integer(headroom) and is_integer(already_counted),
      do: min(base, already_counted + headroom)

  # ---- internals ----------------------------------------------------------

  # `min` over two optional constraints: an absent one imposes nothing.
  defp ceiling(nil, nil), do: nil
  defp ceiling(nil, share) when is_integer(share), do: share
  defp ceiling(max_concurrent, nil) when is_integer(max_concurrent), do: max_concurrent

  defp ceiling(max_concurrent, share) when is_integer(max_concurrent) and is_integer(share),
    do: min(max_concurrent, share)

  # One query: the workspaces metered under this account, as a set. Leaner
  # than `Resolver.workspaces/1`, which loads and sorts the workspace rows for
  # display.
  defp linked_workspace_ids(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.Query.select([:workspace_id])
    |> Ash.read()
    |> case do
      {:ok, links} -> Map.new(links, &{&1.workspace_id, true})
      _ -> %{}
    end
  end

  # Everything holding a slot on some account: the live workers, less parked
  # primaries, plus every admitted dispatch (bd-8suxac) whose worker does not
  # count yet. A worker counts only once `Worker.init/1` has stamped its
  # dispatch context — its name registers before `init/1` runs, and the run-row
  # insert ahead of the stamp can take a while — so the reservation keeps
  # counting until then. `Dispatch` releases it after `Worker.start/1` returns,
  # by which point `init/1` has stamped: the slot is never counted by neither.
  defp occupants do
    dispatches = WorkerRegistry.live_dispatches()
    counted = MapSet.new(dispatches, & &1.registry_key)

    pending =
      Enum.reject(Admission.pending(), &MapSet.member?(counted, &1.registry_key))

    without_parked_primaries(dispatches) ++ pending
  end

  # A primary worker whose own sub-worker (`<task>:fixpass`, `<task>:conflict`,
  # `<task>#review…`) is live is parked on the review gate with no agent
  # process: `Worker.start/1` refuses a second *active* worker per task, and a
  # sub-pass only runs alongside a primary that is waiting (bd-8tjcms). Counting
  # it as well double-counts the ticket's one agent (bd-dp0p58).
  defp without_parked_primaries(dispatches) do
    keys = Enum.map(dispatches, & &1.registry_key)

    Enum.reject(dispatches, fn %{registry_key: key} ->
      Enum.any?(keys, &(&1 != key and WorkerRegistry.owned_by?(&1, key)))
    end)
  end

  # `Arbiter.Quota.provider_code/1` resolves `"gemini"` by probing PATH, so
  # each distinct provider string (and each workspace whose dispatch named
  # none) is resolved once per call rather than once per worker.
  defp filter_matching(dispatches, code) do
    {matching, _cache} =
      Enum.reduce(dispatches, {[], %{}}, fn dispatch, {matching, cache} ->
        {resolved, cache} = resolve_code(dispatch, cache)
        {if(resolved == code, do: [dispatch | matching], else: matching), cache}
      end)

    Enum.reverse(matching)
  end

  defp resolve_code(%{provider: nil, workspace_id: ws_id}, cache) do
    cached(cache, {:default, ws_id}, fn ->
      ws_id |> Arbiter.Quota.default_provider() |> Arbiter.Quota.provider_code()
    end)
  end

  defp resolve_code(%{provider: provider}, cache) do
    cached(cache, {:provider, provider}, fn -> Arbiter.Quota.provider_code(provider) end)
  end

  defp cached(cache, key, fun) do
    case Map.fetch(cache, key) do
      {:ok, value} -> {value, cache}
      :error -> value_into(cache, key, fun.())
    end
  end

  defp value_into(cache, key, value), do: {value, Map.put(cache, key, value)}

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id) when is_binary(id), do: id
  defp workspace_id(_), do: nil
end
