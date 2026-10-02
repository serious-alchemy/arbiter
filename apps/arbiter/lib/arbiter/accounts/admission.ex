defmodule Arbiter.Accounts.Admission do
  @moduledoc """
  Admit a fresh dispatch against its provider account's `max_concurrent`, and
  count it from that moment (bd-8suxac, #207).

  ## The incident

  On 2026-10-01 `claude:default` ran at `max_concurrent=2` with two Claude
  runs live, and four more Claude workers started between 20:11Z and 20:14Z.
  Autopilot admitted none of them: each was a PRPatrol follow-up forced out of
  Backlog through `Arbiter.Worker.Dispatch.dispatch/2` (the `dispatch_forced`
  rows say `dispatched_by: "pr_patrol"`), and until this module nothing on that
  path asked the account anything. The cap was enforced only by the board's
  plan (`Arbiter.Board.Snapshot.effective_max_concurrent/3`), so any dispatch
  the board did not plan — PRPatrol, `arb dispatch`, MCP `worker_dispatch`,
  the dashboard's dispatch button — went straight past it.

  ## The rule

  Every **fresh admission** through `Dispatch.dispatch/2` passes `admit/3`
  before the ticket moves or a worker starts: a ticket that is not In progress
  being started, by anyone, including Autopilot (whose plan can be stale by
  the time its dispatch runs). With no headroom left on the account the
  dispatch is refused with `{:account_at_capacity, info}` — `force: true`
  (`Dispatch`'s `:force_slot`) goes over, and the override is recorded as an
  `account_cap_override` event. Autopilot plans headroom on the workspace's
  default provider while this checks the account the ticket routes to, so it
  can be refused here too; it holds the card briefly and does not page
  (`Arbiter.Board.Autopilot`). Not admissions, and so never refused here (see
  `Arbiter.Accounts.Concurrency`'s moduledoc for how each still counts):

    * resumes and re-dispatches of a ticket already In progress
      (`Arbiter.Worker.ResumeSlot`: stranding work is worse than overshooting);
    * a ticket's own follow-up roles — fix passes, conflict passes, ReviewGate
      reviewers and fix rounds — which never go through `Dispatch.dispatch/2`
      as fresh work;
    * a review dispatch (`review: true`), which reads a PR rather than
      starting work.

  ## An admission counts before its worker exists

  `Concurrency.live_count/2` is registry-derived: a worker counts once
  `Worker.init/1` has stamped its dispatch context on its registry entry. A
  dispatch between the gate and that stamp (resolving a repo, provisioning a
  worktree, the worker's own run-row insert) would otherwise be invisible to
  the next check, and a burst of checks would each see the same free slot. So
  an admission **reserves**: it registers the task in `#{inspect(__MODULE__)}.Registry`
  from the dispatching process, and `live_count/2` counts each reservation
  whose task has no context-stamped worker yet. The reservation dies with that
  process, and `Dispatch` releases it when the dispatch returns, by which
  point `Worker.start/1` has returned — `init/1` has stamped — and the worker
  (if any) is counted instead.

  The check and the reservation run under one lock per account
  (`:global.trans/3`, local node only), so concurrent admissions on one
  account serialize and a burst can admit no more than the headroom.

  Like every other read of the ceiling, an unreadable count fails **open**: a
  bug here must not stop the fleet.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Tasks.Issue

  require Logger

  @registry __MODULE__.Registry

  @typedoc "What a refusal or an override knows about the account."
  @type info :: %{
          task_id: String.t(),
          account: String.t(),
          cap: non_neg_integer(),
          holders: [String.t()]
        }

  @type result ::
          {:ok, :unlimited | :admitted | :forced}
          | {:error, {:account_at_capacity, info()}}
          | {:error, {:provider_constraint, atom() | String.t() | nil, String.t()}}

  @doc """
  Admit `task` onto the account its workspace is metered under for `provider`.

    * `{:ok, :unlimited}` — no account, or one with no ceiling: nothing to count.
    * `{:ok, :admitted}` — headroom was left; the slot is now reserved.
    * `{:ok, :forced}` — no headroom, but `force: true`; reserved and recorded.
    * `{:error, {:account_at_capacity, info}}` — no headroom; nothing reserved.

  Options: `:force`, `:actor` (named in the override event), and `:account` —
  a `ProviderAccount` (or `nil`) the caller already resolved, e.g. the one a
  routing decision picked.

  A ticket's provider constraint (`Arbiter.Agents.ProviderConstraint`,
  bd-13pqcp) is checked before anything is counted or reserved: an account on
  a provider the constraint does not allow is refused with
  `{:error, {:provider_constraint, provider, phrase}}` — never reserved, and
  not overridable by `force`, which goes over a *cap*, not over a ticket's
  stated rule. `Dispatch` has already routed a constrained ticket to an
  allowed provider, so this is the backstop for any caller that reaches
  admission with another one.
  """
  @spec admit(Issue.t(), atom() | String.t() | nil, keyword()) :: result()
  def admit(%Issue{} = task, provider, opts \\ []) do
    account =
      Keyword.get_lazy(opts, :account, fn -> Resolver.account(task.workspace_id, provider) end)

    with :ok <- ProviderConstraint.check(task, (account && account.provider) || provider) do
      admit_on(task, account, provider, opts)
    end
  rescue
    e ->
      Logger.warning("Admission: account check crashed for #{task.id}: #{Exception.message(e)}")
      {:ok, :unlimited}
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
  so `Concurrency` can count the two together. `registry_key` is the task id.
  """
  @spec pending() :: [
          %{
            registry_key: String.t(),
            pid: pid(),
            workspace_id: String.t() | nil,
            provider: String.t() | nil
          }
        ]
  def pending do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn {task_id, pid, %{workspace_id: ws_id, provider: provider}} ->
      if Process.alive?(pid),
        do: [%{registry_key: task_id, pid: pid, workspace_id: ws_id, provider: provider}],
        else: []
    end)
  rescue
    _ -> []
  end

  @doc """
  The operator-facing refusal for `{:error, {:account_at_capacity, info}}` —
  one source of truth for MCP, the REST API (and so the CLI), and the dashboard.
  """
  @spec refusal_message(info()) :: String.t()
  def refusal_message(%{task_id: task_id, account: account, cap: cap, holders: holders}) do
    "provider account #{account} has no free slot to dispatch #{task_id}: its cap is " <>
      "#{cap} (max_concurrent, or this workspace's share) and #{held_by(holders)}. " <>
      "Wait for a run to finish — Autopilot dispatches Ready tickets as slots free — " <>
      "or dispatch over the cap (`arb dispatch --over-cap`, MCP `over_cap: true`); " <>
      "the override is recorded."
  end

  defp held_by([]), do: "nothing holds a slot (the cap itself is 0)"
  defp held_by(holders), do: "#{length(holders)} held by #{Enum.join(holders, ", ")}"

  # ---- internals ------------------------------------------------------------

  defp admit_on(_task, nil, _provider, _opts), do: {:ok, :unlimited}

  defp admit_on(%Issue{} = task, %ProviderAccount{} = account, provider, opts) do
    :global.trans(
      {{__MODULE__, account.id}, self()},
      fn -> decide(task, account, provider, opts) end,
      [node()]
    )
  end

  defp decide(%Issue{} = task, account, provider, opts) do
    case Concurrency.limit(account, task.workspace_id) do
      nil ->
        {:ok, :unlimited}

      cap ->
        holders = Concurrency.holders(account, exclude_task: task.id)

        cond do
          length(holders) < cap ->
            reserve(task, provider)
            {:ok, :admitted}

          Keyword.get(opts, :force) == true ->
            reserve(task, provider)
            record_override(task, info(task, account, cap, holders), opts)
            {:ok, :forced}

          true ->
            {:error, {:account_at_capacity, info(task, account, cap, holders)}}
        end
    end
  end

  # A second concurrent dispatch of the same task finds the key taken: the
  # first holds the slot, and only one of the two can start a worker.
  defp reserve(%Issue{id: id, workspace_id: ws_id}, provider) do
    case Registry.register(@registry, id, %{workspace_id: ws_id, provider: code(provider)}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp code(provider) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  defp code(provider) when is_binary(provider) and provider != "", do: provider
  defp code(_), do: nil

  defp info(%Issue{id: id}, %ProviderAccount{} = account, cap, holders),
    do: %{task_id: id, account: label(account), cap: cap, holders: holders}

  defp label(%ProviderAccount{provider: provider, slug: slug}), do: "#{provider}:#{slug}"

  defp record_override(%Issue{workspace_id: ws_id}, info, opts) do
    Logger.warning(
      "Admission: #{info.task_id} dispatched over #{info.account}'s cap (#{info.cap}, held by " <>
        "#{inspect(info.holders)}) by force from #{inspect(Keyword.get(opts, :actor))}"
    )

    Arbiter.Events.broadcast(ws_id, "account_cap_override", %{
      "task_id" => info.task_id,
      "account" => info.account,
      "cap" => info.cap,
      "holders" => info.holders,
      "actor" => Keyword.get(opts, :actor)
    })
  end
end
