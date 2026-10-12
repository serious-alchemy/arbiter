defmodule Arbiter.Board.WalkInputs do
  @moduledoc """
  What the scheduler walk plans against (DC6, bd-9ycsk4;
  `docs/design/provider-dynamic-concurrency.md` §4.1-§4.2): the capacity sets
  and each Ready card's candidates, as `Arbiter.Board.Scheduler.plan/1`'s
  `:walk`.

  `Arbiter.Board.Snapshot.load/1` reads this only when `scheduler_admission`
  is `shadow` or `enforce`. Under `legacy` nothing here runs, so no admission
  path reads a budget or a seat (I1). Until DC8 the walk it feeds decides no
  dispatch: `Arbiter.Board.AdmissionShadow` records it beside today's. Under
  `enforce` (DC8) its placements are what `Arbiter.Board.Autopilot` dispatches.

  ## The capacity sets

    * **Pools** — one per published `Arbiter.Quota.Budget` of an account's own
      policy (`Arbiter.Quota.Budget.Server`), keyed `{account_id, pool}`, with
      the seats held on it now (`Arbiter.Quota.Seats`, counted live, never from
      a snapshot), its exempt budget (R7), its reason and the account ceiling
      (`cap`, for the shadow record). A provider a workspace's agent pool names
      with no account behind it is `{:unmetered, provider}`, with no budget:
      the machines bound it (§3.5). A metered pool with no published budget is
      absent, and the walk reads it as closed.
    * **Fair share (DC10, §5.3)** — a pool whose account is `budget_split: fair`
      carries `fair: %{seats:, weights:, labels:}`: the seats each workspace
      holds on it (the holders' tickets, resolved to their workspaces), each
      workspace's link `weight`, and its name. The walk's skip rule reads it
      (`Arbiter.Board.FairShare`); a `queue` pool carries none.
    * **Machines** — the primary (`"local"`: its cap and the runs holding it,
      `Arbiter.Nodes.LocalCapacity`), plus every available node while remote
      execution is on (online, healthy, a known cap, NetworkPolicy enforced),
      with its live runs and reservations.

  ## A card's candidates (asked lazily, per card)

    * **A workspace that routes by quota** (`most_quota`, `scored`) —
      `ProviderRouting.availability/3` with `admission: :walk`: every account
      the ticket is *eligible* for, ranked as routing ranks them. Capacity and
      the paced line are the budgets' to answer, so an account at its cap or
      past its line stays a candidate. A ticket its own constraint rules out of
      every account holds itself; one whose accounts are all paused, out of
      auth or circuit-broken waits on the provider layer. With no attached
      candidate at all it takes the agent-pool path, as dispatch does.
    * **Any other workspace** — its `agent.type` pool, filtered by the
      ticket's constraint, in order (failover: an unhealthy provider's budget
      is a hard zero, so the walk moves on to the next). Its account's pool
      is the one its model runs on; with no model to go on, the account's
      lowest budget (§3.1).
    * **The budget that binds the card there** — a policy workspace's budget
      when the card's workspace has one, and the exempt budget when the card's
      own priority is pace-exempt on the account (R7), capped by the
      workspace link's `share`: the same `min(budget, max_concurrent, share)`
      admission holds it to under `enforce` (DC8, `Arbiter.Accounts.SeatCheck`).
    * **Its machines** — `node_groups/4`: the primary only, unless placement
      may send the run to a node (`Arbiter.Nodes.Placement.eligible/1`: a
      podman-backed Claude implementer with a private clone, in a workspace
      that is not `local_only`).

  It does not read a ticket's checkout: a card whose local worktree holds
  uncommitted work is still offered a node, which dispatch then keeps local.

    * **Its repo** (DC9, `Arbiter.Worker.RepoCap`) — a candidate names the
      `{workspace_id, repo}` of the card when that repo has a
      `worker.repos.<repo>.max_concurrent`, and the walk's `repos` holds each
      capped repo with the implementer runs in it now (counted live). A
      workspace with no cap reads and counts nothing; the walk reads an unnamed
      repo as unbounded.

  Options (all seams): `:budgets`, `:seats`, `:holders`, `:weights`, `:shares`, `:accounts`, `:local`
  (`%{cap:, used:}`), `:nodes` (overview rows), `:remote_available?`,
  `:repo_counts` (`%{{workspace_id, repo} => runs}`, or a function returning
  it), `:routing_opts` (forwarded to `availability/3`).
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Nodes.Capacity
  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Overview
  alias Arbiter.Nodes.Placement
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server, as: BudgetServer
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Seats
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueRepo
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitLayout
  alias Arbiter.Worker.RepoCap

  @local "local"

  # agy's two pools, as the board's chips name them (§9).
  @pool_suffixes %{
    "antigravity:gemini_models" => "gemini",
    "antigravity:claude_and_gpt_models" => "claude-gpt"
  }

  @doc """
  The `:walk` for `Scheduler.plan/1`: `%{pools:, nodes:, candidates:}`.
  `default` is the board's workspace (a card with none is read as in it);
  `issues` are the board's tickets, of which the Ready ones are the walk's.
  """
  @spec gather(Workspace.t() | nil, [map()], keyword()) :: map()
  def gather(default, issues, opts \\ []) do
    budgets = Keyword.get_lazy(opts, :budgets, &BudgetServer.all/0)
    seats = Keyword.get_lazy(opts, :seats, &Seats.counts/0)
    accounts = Keyword.get_lazy(opts, :accounts, &read_accounts/0) |> Map.new(&{&1.id, &1})
    fair = fair_inputs(budgets, accounts, opts)
    queued = Enum.filter(issues, &(Lifecycle.state_of(&1) == :queued))
    workspaces = workspaces(default, queued)
    links = links(Map.values(workspaces))
    remote = remote_nodes(opts)
    repo_caps = repo_caps(workspaces)

    ctx = %{
      repo_caps: repo_caps,
      issues: Map.new(queued, &{&1.id, &1}),
      workspaces: workspaces,
      default: default,
      links: links,
      shares: Keyword.get_lazy(opts, :shares, fn -> read_shares(Map.keys(workspaces)) end),
      budgets: Map.new(budgets, &{{&1.account, &1.pool, &1.policy_workspace}, &1}),
      remote: remote,
      routing_opts: Keyword.get(opts, :routing_opts, [])
    }

    %{
      pools: budgets |> pools(seats, accounts, fair) |> Map.merge(unmetered(links)),
      nodes: Map.put(remote, @local, local(opts)),
      repos: repos(repo_caps, opts),
      candidates: &candidates(&1, ctx)
    }
  end

  @doc """
  The machines that may run a card, as node groups in `Arbiter.Nodes.Placement`'s
  preference (the walk ranks inside a group by load, then name). `remote_ok?`
  is `Placement.eligible/1`'s answer for the run; `remote` the available nodes
  (`%{id => %{constrained?:, workspace_ids:}}`), a node pinned to other
  workspaces left out.

    * `local_only`, or a run no node may take — the primary only;
    * `prefer_remote` — unconstrained nodes, then the primary, then constrained
      nodes (a run whose only nodes are constrained goes local first);
    * `remote_only` — unconstrained nodes, then constrained ones, never the
      primary.
  """
  @spec node_groups(Placement.mode(), boolean(), map(), String.t() | nil) :: [[String.t()]]
  def node_groups(mode, remote_ok?, remote, workspace_id)

  def node_groups(:local_only, _remote_ok?, _remote, _ws_id), do: [[@local]]
  def node_groups(_mode, false, _remote, _ws_id), do: [[@local]]

  def node_groups(mode, true, remote, workspace_id) do
    {constrained, free} =
      remote
      |> Enum.filter(fn {_id, node} ->
        pin_allows?(Map.get(node, :workspace_ids, []), workspace_id)
      end)
      |> Enum.split_with(fn {_id, node} -> Map.get(node, :constrained?, false) end)

    free = free |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    constrained = constrained |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    case mode do
      :prefer_remote -> [free, [@local], constrained]
      :remote_only -> [free, constrained]
    end
    |> Enum.reject(&(&1 == []))
  end

  defp pin_allows?([], _workspace_id), do: true
  defp pin_allows?(pins, workspace_id), do: workspace_id in pins

  # ---- pools ----------------------------------------------------------------

  defp pools(budgets, seats, accounts, fair) do
    for %Budget{policy_workspace: nil, account: id, pool: pool} = b <- budgets, into: %{} do
      key = {id, pool}

      base = %{
        budget: b.budget,
        seats: Map.get(seats, key, 0),
        exempt_budget: b.exempt_budget,
        label: pool_label(Map.get(accounts, id), pool),
        reason: b.reason,
        binding: b.binding,
        cap: ceiling(b.ceiling)
      }

      {key, put_fair(base, Map.get(fair, key))}
    end
  end

  defp put_fair(pool, nil), do: pool
  defp put_fair(pool, fair), do: Map.put(pool, :fair, fair)

  defp unmetered(links) do
    for {{_ws_id, provider}, nil} <- links, into: %{} do
      {{:unmetered, provider},
       %{budget: :unlimited, seats: 0, label: provider, reason: "no account: unmetered"}}
    end
  end

  @doc false
  def pool_label(nil, pool), do: pool

  def pool_label(%ProviderAccount{provider: provider, slug: slug}, pool) do
    base = "#{provider}:#{slug}"

    case Map.get(@pool_suffixes, pool) do
      nil -> if pool == to_string(provider), do: base, else: "#{base} #{pool}"
      suffix -> "#{base} #{suffix}"
    end
  end

  defp ceiling(%{} = ceiling) do
    ceiling
    |> Map.take([:max_concurrent, :share])
    |> Map.values()
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp ceiling(_), do: nil

  # ---- fair share (DC10) -----------------------------------------------------

  @doc """
  `{account_id, pool} => %{seats:, weights:, labels:}` for every published pool
  of an account that splits `fair`; nothing is read for a board with none.
  `accounts` is `%{id => ProviderAccount}`. Options: `:holders`, `:weights`, `:workspace_of` (`ticket_id => workspace_id`).
  """
  @spec fair_inputs([Budget.t()], map(), keyword()) :: %{
          optional({String.t(), String.t()}) => map()
        }
  def fair_inputs(budgets, accounts, opts) do
    pool_keys =
      for %Budget{policy_workspace: nil, account: id, pool: pool} <- budgets,
          match?(%ProviderAccount{budget_split: :fair}, Map.get(accounts, id)),
          do: {id, pool}

    if pool_keys == [] do
      %{}
    else
      holders = Keyword.get_lazy(opts, :holders, &Seats.holders/0)

      workspace_of =
        Keyword.get_lazy(opts, :workspace_of, fn -> holder_workspaces(pool_keys, holders) end)

      weights = Keyword.get_lazy(opts, :weights, fn -> read_weights(pool_keys) end)
      names = workspace_names(workspace_of, weights)

      Map.new(pool_keys, fn {account, _pool} = key ->
        seats =
          holders
          |> Map.get(key, [])
          |> Enum.map(&Map.get(workspace_of, Seats.base_task_id(&1)))
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()

        account_weights = Map.get(weights, account, %{})

        labels =
          Map.new(Enum.uniq(Map.keys(seats) ++ Map.keys(account_weights)), fn id ->
            {id, Map.get(names, id, id)}
          end)

        {key, %{seats: seats, weights: account_weights, labels: labels}}
      end)
    end
  rescue
    _ -> %{}
  end

  # `ticket_id => workspace_id` for every ticket holding a seat on those pools.
  defp holder_workspaces(pool_keys, holders) do
    ids =
      pool_keys
      |> Enum.flat_map(&Map.get(holders, &1, []))
      |> Enum.map(&Seats.base_task_id/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Issue
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :workspace_id])
      |> Ash.read!()
      |> Map.new(&{&1.id, &1.workspace_id})
    end
  end

  # `account_id => %{workspace_id => weight}` from the links.
  defp read_weights(pool_keys) do
    ids = pool_keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id in ^ids)
    |> Ash.read!()
    |> Enum.group_by(& &1.provider_account_id, &{&1.workspace_id, &1.weight})
    |> Map.new(fn {account, pairs} -> {account, Map.new(pairs)} end)
  end

  defp workspace_names(workspace_of, weights) do
    ids =
      (Map.values(workspace_of) ++ Enum.flat_map(Map.values(weights), &Map.keys/1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Workspace
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1.name})
    end
  rescue
    _ -> %{}
  end

  # ---- machines -------------------------------------------------------------

  defp local(opts) do
    opts
    |> Keyword.get_lazy(:local, fn ->
      %{cap: LocalCapacity.cap().offered, used: length(LocalCapacity.holders())}
    end)
    |> Map.put(:label, @local)
  end

  defp remote_nodes(opts) do
    if Keyword.get_lazy(opts, :remote_available?, &Placement.remote_execution_available?/0) do
      rows = Keyword.get_lazy(opts, :nodes, &Overview.node_rows/0)
      reserved = Placement.reservations() |> Enum.frequencies_by(& &1.node)

      for row <- rows, available?(row), into: %{} do
        {row.id,
         %{
           cap: Capacity.offered(row),
           used: (Map.get(row, :live) || 0) + Map.get(reserved, row.id, 0),
           label: Map.get(row, :name) || row.id,
           constrained?: Map.get(row, :constrained?, false) == true,
           workspace_ids: Map.get(row, :workspace_ids) || []
         }}
      end
    else
      %{}
    end
  end

  defp available?(row) do
    Map.get(row, :state) == :online and Map.get(row, :health) == :ready and
      is_integer(Map.get(row, :max)) and row.max > 0 and Placement.network_enforced?(row)
  end

  # ---- repos (DC9) ----------------------------------------------------------

  # `%{workspace_id => %{repo => cap}}` for the workspaces that cap a repo.
  defp repo_caps(workspaces) do
    for {id, ws} <- workspaces, caps = RepoCap.limits(ws), caps != %{}, into: %{}, do: {id, caps}
  end

  # Each capped repo and the implementer runs in it now, read live and only
  # when some workspace caps a repo (I1: nothing is read otherwise).
  defp repos(repo_caps, _opts) when map_size(repo_caps) == 0, do: %{}

  defp repos(repo_caps, opts) do
    counts =
      case Keyword.get_lazy(opts, :repo_counts, fn -> &RepoCap.counts/0 end) do
        fun when is_function(fun, 0) -> fun.()
        counts -> counts
      end

    for {ws_id, caps} <- repo_caps, {repo, cap} <- caps, into: %{} do
      {{ws_id, repo}, %{cap: cap, used: Map.get(counts, {ws_id, repo}, 0), label: repo}}
    end
  end

  # The card's capped repo, as the walk keys it; nothing when the card's repo
  # has no cap. An implicit repo resolves as dispatch does (the sole configured
  # repo, else the workspace's `default_repo`).
  defp put_repo(candidates, card, ctx) do
    case card_repo(card, ctx) do
      nil -> candidates
      key -> Enum.map(candidates, &Map.put(&1, :repo, key))
    end
  end

  defp card_repo(card, ctx) do
    ws_id = Map.get(card, :workspace_id) || (ctx.default && ctx.default.id)

    with %{} = caps <- Map.get(ctx.repo_caps, ws_id),
         %{repo: stored} <- Map.get(ctx.issues, card.id),
         repo when is_map_key(caps, repo) <- implied_repo(ws_id, stored) do
      {ws_id, repo}
    else
      _ -> nil
    end
  end

  defp implied_repo(ws_id, stored) do
    case IssueRepo.resolve(ws_id, stored) do
      {:ok, repo} when is_binary(repo) -> repo
      _ -> stored
    end
  end

  # ---- candidates -----------------------------------------------------------

  defp candidates(card, ctx) do
    ws =
      case Map.get(card, :workspace_id) do
        nil -> ctx.default
        id -> Map.get(ctx.workspaces, id)
      end

    issue = Map.get(ctx.issues, card.id)

    cond do
      is_nil(ws) or is_nil(issue) -> {:none, "its ticket or workspace could not be read"}
      ProviderRouting.enabled?(ws) -> ws |> routed(issue, ctx) |> with_repo(card, ctx)
      true -> ws |> pooled(issue, ctx) |> with_repo(card, ctx)
    end
  rescue
    e -> {:none, "its candidates could not be read (#{Exception.message(e)})"}
  catch
    :exit, reason -> {:none, "its candidates could not be read (#{inspect(reason, limit: 5)})"}
  end

  defp with_repo([_ | _] = candidates, card, ctx), do: put_repo(candidates, card, ctx)
  defp with_repo(other, _card, _ctx), do: other

  defp routed(ws, issue, ctx) do
    case ProviderRouting.availability(ws, issue, Keyword.put(ctx.routing_opts, :admission, :walk)) do
      %{available: [_ | _] = available} ->
        Enum.map(available, &candidate(ws, issue, &1.account, &1.pool, &1.agent_type, ctx))

      %{dropped: [_ | _] = dropped} ->
        from_drops(issue, dropped)

      _no_candidates ->
        pooled(ws, issue, ctx)
    end
  end

  defp from_drops(issue, dropped) do
    case Enum.reject(dropped, &(&1.reason == "provider_constraint")) do
      [] ->
        {:hold,
         {:provider_constraint,
          "#{ProviderConstraint.describe(issue)}: no attached implementer account is allowed"}}

      others ->
        {:none, Enum.map_join(others, "; ", &ProviderRouting.describe_drop/1)}
    end
  end

  defp pooled(ws, issue, ctx) do
    pool = ws |> Agents.agent_pool() |> Enum.map(&to_string/1)

    case ProviderConstraint.filter(issue, pool) do
      [] ->
        {:hold,
         {:provider_constraint,
          "#{ProviderConstraint.describe(issue)}: no allowed provider in the agent pool " <>
            "(#{Enum.join(pool, ", ")})"}}

      allowed ->
        Enum.map(allowed, &pooled_candidate(ws, issue, &1, ctx))
    end
  end

  defp pooled_candidate(ws, issue, provider, ctx) do
    case Map.get(ctx.links, {ws.id, provider}) do
      %ProviderAccount{} = account ->
        candidate(ws, issue, account, unrouted_pool(account, ctx), provider, ctx)

      nil ->
        %{pool: {:unmetered, provider}, nodes: groups(ws, issue, provider, ctx)}
    end
  end

  # No predicted model on the pool path: a one-pool provider's pool, else the
  # account's lowest published budget (§3.1).
  defp unrouted_pool(%ProviderAccount{id: id, provider: provider}, ctx) do
    own = for {{^id, _pool, nil}, budget} <- ctx.budgets, do: budget

    case Budget.lowest(own) do
      %Budget{pool: pool} -> pool
      nil -> ModelFamily.classify(provider, nil).pool
    end
  end

  defp candidate(ws, issue, account, pool, provider, ctx) do
    %{pool: {account.id, pool}, nodes: groups(ws, issue, provider, ctx)}
    |> put_hold(hold(ws, issue, provider))
    |> put_budget(account, pool, ws, issue, ctx)
  end

  # The budget that binds this card on the pool, when it is not the pool's own:
  # its workspace's policy variant, or the exempt budget for an exempt card —
  # capped by the workspace link's `share`, as admission caps it (DC8:
  # `min(budget, max_concurrent, share)`, `Arbiter.Accounts.SeatCheck`).
  defp put_budget(candidate, account, pool, ws, issue, ctx) do
    variant = Map.get(ctx.budgets, {account.id, pool, ws.id})
    budget = variant || Map.get(ctx.budgets, {account.id, pool, nil})

    own =
      cond do
        is_nil(budget) -> nil
        exempt?(account, ws, issue) and is_integer(budget.exempt_budget) -> budget.exempt_budget
        variant != nil -> budget.budget
        true -> nil
      end

    case shared(own, budget, Map.get(ctx.shares, {ws.id, account.id})) do
      nil -> candidate
      n -> Map.put(candidate, :budget, n)
    end
  end

  defp shared(own, _budget, nil), do: own
  defp shared(_own, nil, _share), do: nil
  defp shared(nil, %Budget{budget: :unlimited}, share), do: share
  defp shared(nil, %Budget{budget: pool_budget}, share), do: min(pool_budget, share)
  defp shared(:unlimited, _budget, share), do: share
  defp shared(own, _budget, share), do: min(own, share)

  defp exempt?(account, ws, %{priority: priority}) when is_integer(priority),
    do: Gate.pace_exempt?({account, ws}, priority)

  defp exempt?(_account, _ws, _issue), do: false

  defp groups(ws, issue, provider, ctx) do
    mode = Placement.mode(ws)

    verdict = if mode == :local_only, do: nil, else: eligibility(ws, issue, provider, mode)

    # bd-21r811: a `remote_only` run that pushes with a scoped git credential has
    # no machine (a node cannot carry the key; the primary is off limits): held.
    if mode == :remote_only and verdict == {:local_only, :scoped_git_credential} do
      []
    else
      node_groups(mode, ctx.remote != %{} and verdict == :ok, ctx.remote, ws.id)
    end
  end

  defp put_hold(candidate, nil), do: candidate
  defp put_hold(candidate, hold), do: Map.put(candidate, :hold, hold)

  # Why a card has no machine at all, for the capacity explainer; `nil` otherwise.
  defp hold(ws, issue, provider) do
    mode = Placement.mode(ws)

    if mode == :remote_only and
         eligibility(ws, issue, provider, mode) == {:local_only, :scoped_git_credential},
       do: :scoped_git_credential
  end

  defp eligibility(ws, issue, provider, mode) do
    no_pr? = Issue.no_pr_type?(issue.issue_type)

    request = %{
      task_id: issue.id,
      kind: :implementer,
      provider: provider,
      layout: layout(ws, issue),
      mode: mode,
      no_pr?: no_pr?,
      # The inspect checkout is what a task/research dispatch gets by default
      # (`Worker.Dispatch.node_request/3`), a read-only clone a node can be handed.
      inspect?: no_pr?,
      local_work?: false,
      scoped_git_credential?:
        Placement.scoped_git_credential?(ws, string_or_nil(Map.get(issue, :repo))),
      workspace_id: ws.id
    }

    Placement.eligible(request)
  end

  defp string_or_nil(repo) when is_binary(repo) and repo != "", do: repo
  defp string_or_nil(_repo), do: nil

  defp layout(ws, issue) do
    repo =
      case Map.get(issue, :repo) do
        repo when is_binary(repo) and repo != "" -> repo
        _ -> nil
      end

    ws |> SecurityPolicy.resolve(%{}, repo) |> GitLayout.for_policy()
  end

  # ---- reads ----------------------------------------------------------------

  # `{workspace_id, account_id} => share` for every link of these workspaces
  # that sets one; one read. An unreadable table caps nothing.
  defp read_shares([]), do: %{}

  defp read_shares(workspace_ids) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id in ^workspace_ids and not is_nil(share))
    |> Ash.read!()
    |> Map.new(&{{&1.workspace_id, &1.provider_account_id}, &1.share})
  rescue
    _ -> %{}
  end

  defp read_accounts do
    ProviderAccount |> Ash.Query.filter(is_nil(deleted_at)) |> Ash.read!()
  end

  defp workspaces(default, queued) do
    ids = queued |> Enum.map(&Map.get(&1, :workspace_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    known = if default, do: %{default.id => default}, else: %{}

    Enum.reduce(ids, known, fn id, acc ->
      if Map.has_key?(acc, id), do: acc, else: put_workspace(acc, id)
    end)
  end

  defp put_workspace(acc, id) do
    case Ash.get(Workspace, id) do
      {:ok, %Workspace{} = ws} -> Map.put(acc, id, ws)
      _ -> acc
    end
  end

  # `{workspace_id, provider} => account | nil` for every provider each
  # workspace's agent pool names.
  defp links(workspaces) do
    for ws <- workspaces, provider <- Agents.agent_pool(ws), into: %{} do
      provider = to_string(provider)
      {{ws.id, provider}, Resolver.account(ws.id, provider)}
    end
  end
end
