defmodule Arbiter.Worker.RepoCap do
  @moduledoc """
  The repo cap, `worker.repos.<repo>.max_concurrent` (DC9, bd-7oy77e; design
  `docs/design/provider-dynamic-concurrency.md` §5.2): how many tickets in one
  workspace's repo may be *written* at once. It bounds shared test services, the
  rate at which new branches reach CI and the merge queue, and the conflicts that
  racing branches cause.

  **It holds only a fresh dispatch.** A follow-up (a resume, a fix pass, a
  conflict pass, a ReviewGate fix round) finishes a ticket the cap already
  admitted, and finishing is what cuts merge churn, so it is never held (I9).
  It only tightens: unset is no cap.

  **Enforced only under `scheduler_admission: enforce`.** Until DC8 nothing may
  change a dispatch decision (I1, I2), so `Arbiter.Worker.Dispatch`'s
  `ensure_repo_capacity/2` is a no-op under `legacy` and `shadow` and never
  reads a count. The scheduler walk (`Arbiter.Board.WalkInputs`) and the
  capacity display (in `Arbiter.Board`) read the same count beside today's
  decision.

  ## What counts

  An **implementer run** in the workspace's repo, derived from
  `Arbiter.Worker.Registry` (each entry stamps its `repo`) and the admission
  reservations — there is no counter, so a worker that dies releases its run
  with no decrement:

    * the implementer (fresh, re-dispatched, resumed), a CI fix pass
      (`<task>:fixpass`), a conflict pass (`<task>:conflict`) and a ReviewGate
      fix round (`<task>#review#impl<N>`);
    * a reservation (`admit/3`) whose worker has not registered yet.

  Not counted: reviewers (`<task>#review`, `#r<N>`, `#v<N>`, `#t<N>`), a primary
  worker whose ticket is no longer In progress (a Merging ticket's parked
  worker, so a pipeline in flight is not a run: O3 stays at "the spec counts
  runs"), and a primary released to wait for CI, which is not writing. A
  primary whose ticket cannot be read fails closed and counts.

  A run that stamped no repo takes its ticket's. One with neither is not in any
  repo and counts nowhere.

  ## Admission

  `admit/3` checks and reserves under one lock per (workspace, repo)
  (`:global.trans/3`, local node only), like `Arbiter.Accounts.Admission`, so a
  burst of dispatches can admit no more than the headroom. The reservation
  lives in `#{inspect(__MODULE__)}.Registry`, owned by the dispatching process,
  and `Dispatch` releases it when the dispatch returns. Like every other read of
  a ceiling, an unreadable count fails **open**.

  `holders/2` and `limits/1` are pure; `counts/0` and `count/2` read the live
  state.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @registry __MODULE__.Registry

  @typedoc "A repo's runs are counted per (workspace id, repo name)."
  @type key :: {workspace_id :: String.t() | nil, repo :: String.t()}

  @type entry :: %{
          required(:registry_key) => String.t(),
          required(:workspace_id) => String.t() | nil,
          optional(:repo) => String.t() | nil,
          optional(:released) => boolean(),
          optional(:reservation) => boolean(),
          optional(any()) => any()
        }

  @typedoc "What a refusal or an override knows about the repo."
  @type info :: %{
          task_id: String.t(),
          repo: String.t(),
          cap: pos_integer(),
          holders: [String.t()]
        }

  @type result ::
          {:ok, :unlimited | :admitted | :forced}
          | {:error, {:repo_at_capacity, info()}}

  # ---- the key ----------------------------------------------------------------

  @doc """
  The caps a workspace config (or workspace) sets: `%{repo => cap}`. Only a
  positive integer is a cap; validation refuses anything else, and a stored
  value that slipped through reads as no cap.
  """
  @spec limits(Workspace.t() | map() | nil) :: %{String.t() => pos_integer()}
  def limits(%Workspace{config: config}), do: limits(config)

  def limits(%{} = config) do
    case get_in(config, ["worker", "repos"]) do
      %{} = repos ->
        for {repo, %{"max_concurrent" => n}} <- repos, is_integer(n) and n > 0, into: %{} do
          {to_string(repo), n}
        end

      _ ->
        %{}
    end
  end

  def limits(_), do: %{}

  @doc "The cap on `repo`, or `nil` when it has none."
  @spec limit(Workspace.t() | map() | nil, String.t() | nil) :: pos_integer() | nil
  def limit(config, repo) when is_binary(repo), do: config |> limits() |> Map.get(repo)
  def limit(_config, _repo), do: nil

  @doc """
  Is this registry key an implementer run, the kind the cap counts? A key with
  no `#` is the ticket's own worker or its `:fixpass` / `:conflict` pass; one
  under `#` is a ReviewGate worker, an implementer only when it is a fix round
  (`#impl<N>`) and a reviewer otherwise.
  """
  @spec implementer_key?(String.t()) :: boolean()
  def implementer_key?(registry_key) when is_binary(registry_key) do
    case String.split(registry_key, "#") do
      [_plain] -> true
      [_base | segments] -> Enum.any?(segments, &String.starts_with?(&1, "impl"))
    end
  end

  # ---- the count --------------------------------------------------------------

  @doc """
  The pure core. `entries` are registry entries (`Registry.live_dispatches/0`'s
  shape, plus `reservation: true` for a reservation) and `tickets` the stored
  `%{id => %{state:, repo:}}` of the tickets involved. Returns the holders per
  (workspace, repo): the registry keys of the implementer runs.
  """
  @spec holders([entry()], %{optional(String.t()) => map()}) :: %{key() => [String.t()]}
  def holders(entries, tickets) when is_list(entries) and is_map(tickets) do
    entries
    |> drop_shadowed_reservations()
    |> Enum.filter(&(implementer_key?(&1.registry_key) and counts?(&1, tickets)))
    |> Enum.map(&{{&1.workspace_id, repo_of(&1, tickets)}, &1.registry_key})
    |> Enum.reject(fn {{_ws, repo}, _key} -> is_nil(repo) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, list} -> {key, Enum.sort(list)} end)
  end

  @doc "`holders/2` over the live registry and reservations."
  @spec holders() :: %{key() => [String.t()]}
  def holders do
    entries = live_entries()
    holders(entries, tickets(entries))
  end

  @doc "`holders/0`, as counts."
  @spec counts() :: %{key() => non_neg_integer()}
  def counts, do: Map.new(holders(), fn {key, list} -> {key, length(list)} end)

  @doc "Implementer runs in the workspace's repo right now."
  @spec count(String.t() | nil, String.t() | nil) :: non_neg_integer()
  def count(workspace_id, repo), do: holders() |> Map.get({workspace_id, repo}, []) |> length()

  # A reservation counts only until its worker's entry exists, as `Seats` and
  # `Concurrency` do: the registered entry takes over under the same key.
  defp drop_shadowed_reservations(entries) do
    registered = for e <- entries, not reserved?(e), into: MapSet.new(), do: e.registry_key
    Enum.reject(entries, &(reserved?(&1) and MapSet.member?(registered, &1.registry_key)))
  end

  defp reserved?(entry), do: Map.get(entry, :reservation, false) == true

  # A reservation is a run about to start. A primary counts while its ticket is
  # In progress (or cannot be read) and is not parked waiting for CI; a pass or
  # a fix round is a live run by existing.
  defp counts?(entry, tickets) do
    key = entry.registry_key

    cond do
      reserved?(entry) -> true
      key != base_task_id(key) -> true
      Map.get(entry, :released, false) == true -> false
      true -> pin_holder?(Map.get(tickets, key, :unreadable))
    end
  end

  defp pin_holder?(:unreadable), do: true
  defp pin_holder?(%{state: state}), do: state == :active

  defp repo_of(entry, tickets) do
    stamped(Map.get(entry, :repo)) ||
      case Map.get(tickets, base_task_id(entry.registry_key)) do
        %{repo: repo} -> stamped(repo)
        _ -> nil
      end
  end

  # `Arbiter.Worker` stamps "unknown" for a dispatch that named no repo.
  defp stamped(repo) when is_binary(repo) and repo not in ["", "unknown"], do: repo
  defp stamped(_), do: nil

  @doc "The ticket a registry key belongs to: the key up to its first `:` or `#`."
  @spec base_task_id(String.t()) :: String.t()
  def base_task_id(registry_key), do: Arbiter.Quota.Seats.base_task_id(registry_key)

  defp live_entries do
    reservations = Enum.map(pending(), &Map.put(&1, :reservation, true))
    WorkerRegistry.live_dispatches() ++ reservations
  end

  # The stored state and repo of every ticket the entries belong to. A ticket
  # that cannot be read is left out, which `counts?/2` reads as fail-closed.
  defp tickets(entries) do
    ids = entries |> Enum.map(&base_task_id(&1.registry_key)) |> Enum.uniq()

    case read_tickets(ids) do
      {:ok, found} ->
        Map.new(found, fn t -> {t.id, %{state: Lifecycle.state_of(t), repo: t.repo}} end)

      :error ->
        %{}
    end
  end

  defp read_tickets([]), do: {:ok, []}

  defp read_tickets(ids) do
    Issue |> Ash.Query.filter(id in ^ids) |> Ash.read()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # ---- admission --------------------------------------------------------------

  @doc """
  Admit `task` into `repo`: check the repo's cap and reserve the run, under one
  lock per (workspace, repo).

    * `{:ok, :unlimited}` — no repo, or no cap: nothing to count.
    * `{:ok, :admitted}` — headroom was left; the run is now reserved.
    * `{:ok, :forced}` — no headroom, but `force: true`; reserved and recorded as
      a `repo_cap_override` event.
    * `{:error, {:repo_at_capacity, info}}` — no headroom; nothing reserved.

  Options: `:force`, `:actor` (named in the override event), and `:limit`, a
  cap the caller already resolved (else read from the task's workspace).
  """
  @spec admit(Issue.t(), String.t() | nil, keyword()) :: result()
  def admit(task, repo, opts \\ [])

  def admit(%Issue{} = task, repo, opts) when is_binary(repo) and repo != "" do
    case Keyword.get_lazy(opts, :limit, fn -> workspace_limit(task, repo) end) do
      nil ->
        {:ok, :unlimited}

      cap ->
        :global.trans(
          {{__MODULE__, task.workspace_id, repo}, self()},
          fn -> decide(task, repo, cap, opts) end,
          [node()]
        )
    end
  rescue
    e ->
      Logger.warning("RepoCap: repo check crashed for #{task.id}: #{Exception.message(e)}")
      {:ok, :unlimited}
  end

  def admit(%Issue{}, _repo, _opts), do: {:ok, :unlimited}

  defp workspace_limit(%Issue{workspace_id: ws_id}, repo) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> limit(ws, repo)
      _ -> nil
    end
  end

  defp decide(%Issue{} = task, repo, cap, opts) do
    held = holders() |> Map.get({task.workspace_id, repo}, []) |> List.delete(task.id)

    cond do
      length(held) < cap ->
        reserve(task, repo)
        {:ok, :admitted}

      Keyword.get(opts, :force) == true ->
        reserve(task, repo)
        record_override(task, info(task, repo, cap, held), opts)
        {:ok, :forced}

      true ->
        {:error, {:repo_at_capacity, info(task, repo, cap, held)}}
    end
  end

  # A second concurrent dispatch of the same task finds the key taken: the
  # first holds the run, and only one of the two can start a worker.
  defp reserve(%Issue{id: id, workspace_id: ws_id}, repo) do
    case Registry.register(@registry, id, %{workspace_id: ws_id, repo: repo}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc """
  Drop the calling process's reservation for `task_id`. A no-op when it holds
  none — only the process that reserved can release.
  """
  @spec release(String.t()) :: :ok
  def release(task_id) when is_binary(task_id) do
    Registry.unregister(@registry, task_id)
  rescue
    _ -> :ok
  end

  @doc """
  Every live reservation, shaped like `Arbiter.Worker.Registry.live_dispatches/0`
  so `holders/2` counts the two together. `registry_key` is the task id.
  """
  @spec pending() :: [entry()]
  def pending do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn {task_id, pid, %{workspace_id: ws_id, repo: repo}} ->
      if Process.alive?(pid),
        do: [%{registry_key: task_id, pid: pid, workspace_id: ws_id, repo: repo}],
        else: []
    end)
  rescue
    _ -> []
  end

  @doc """
  The operator-facing refusal for `{:error, {:repo_at_capacity, info}}` — one
  source of truth for MCP, the REST API (and so the CLI) and the dashboard.
  """
  @spec refusal_message(info()) :: String.t()
  def refusal_message(%{task_id: task_id, repo: repo, cap: cap, holders: holders}) do
    "repo #{repo}: #{length(holders)} of #{cap} implementer runs — no free run to dispatch " <>
      "#{task_id} (`worker.repos.#{repo}.max_concurrent`; #{held_by(holders)}). Wait for a " <>
      "run to finish — Autopilot dispatches Ready tickets as runs free — or dispatch over " <>
      "the cap (`arb dispatch --over-cap`, MCP `over_cap: true`); the override is recorded."
  end

  defp held_by([]), do: "nothing holds a run (the cap itself is 0)"
  defp held_by(holders), do: "held by #{Enum.join(holders, ", ")}"

  defp info(%Issue{id: id}, repo, cap, holders),
    do: %{task_id: id, repo: repo, cap: cap, holders: holders}

  defp record_override(%Issue{workspace_id: ws_id}, info, opts) do
    Logger.warning(
      "RepoCap: #{info.task_id} dispatched over repo #{info.repo}'s cap (#{info.cap}, held by " <>
        "#{inspect(info.holders)}) by force from #{inspect(Keyword.get(opts, :actor))}"
    )

    Arbiter.Events.broadcast(ws_id, "repo_cap_override", %{
      "task_id" => info.task_id,
      "repo" => info.repo,
      "cap" => info.cap,
      "holders" => info.holders,
      "actor" => Keyword.get(opts, :actor)
    })
  end
end
