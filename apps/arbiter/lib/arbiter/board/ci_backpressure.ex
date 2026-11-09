defmodule Arbiter.Board.CiBackpressure do
  @moduledoc """
  CI backpressure (#1126): hold new dispatches for a repo while its forge's CI
  queue is saturated.

  Arbiter can open MRs much faster than a repo's CI can test them. A runner
  pool that finishes two pipelines at once and is handed twenty leaves every
  in-flight ticket waiting hours on its pipeline — and every fix round and
  re-run joins the same queue. Starting more work makes all of it later.

  ## Config

      worker.repos.<repo>.ci_backpressure = {max_pending: N, max_oldest_pending_min: M}

  Off by default (no block, or neither threshold). Either threshold alone is a
  gate; with both, either one trips it. `max_pending` holds at that many
  pending MR pipelines *or more*; `max_oldest_pending_min` holds once the
  oldest pending pipeline is *older than* that many minutes.

  ## Signal

  The repo's MR pipelines that have not started: GitLab `pending`, `created`
  and `waiting_for_resource` pipelines from a merge request event, GitHub
  workflow runs that are `queued` for a pull request (`Merger.ci_queue/0`).
  `poll/2` reads it through the repo's own merger; `Cache` memoizes it for
  #{div(60_000, 1000)}s (`:interval_ms`), so the board's many readers cost one
  forge call per repo per interval. `Refresher` also polls every gated repo on
  a timer, whether or not a card is queued, so the first card promoted after a
  quiet spell finds a fresh reading rather than a stale one.

  A card is never waved through on *no information*: with no reading yet (first
  poll in flight), or after a failed poll, a fresh dispatch is held for a tick.
  A forge that stays unreadable for `Cache.max_failures/0` polls in a row is
  logged and **fails open**: no hold, never a stalled repo.

  Every change of decision (held, released) is logged once per repo at info,
  naming the pending count and the oldest pending age.

  ## Effect

  `holds/3` returns a `{:hold, detail}` per Ready ticket, which the board
  (`Arbiter.Board.Snapshot`) hands the scheduler as that card's own hold
  (`{:ci_saturated, detail}`, `held — CI saturated (6 pending, oldest 42m)`):
  the card is not started, the card behind it for another repo is. It lifts by
  itself when the queue drains below the thresholds.

  Only a **fresh dispatch** is ever asked: the hold is a scheduler hold on a
  Ready card. A CI fix pass, a conflict pass, a ReviewGate fix round, a resume
  and the merge queue's work on an already-open MR never reach it — they drain
  the queue, so holding them would only lengthen it. A P0 ticket is exempt.
  A manual dispatch (`arb worker dispatch`) is the operator overriding the
  scheduler and is not held either.

  `status/2` is the per-repo read behind `scheduler_status` and `arb prime`.
  """

  alias Arbiter.Board.CiBackpressure.Cache
  alias Arbiter.Mergers
  alias Arbiter.Mergers.ForgeRepos
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Workspace

  require Logger

  @interval_ms 60_000

  @type limits :: %{
          max_pending: pos_int_or_nil(),
          max_oldest_pending_min: pos_int_or_nil()
        }
  @typep pos_int_or_nil :: pos_integer() | nil
  @type signal :: Cache.signal()

  @doc """
  The gates a workspace's config sets: `%{repo => limits}`. A threshold is a
  positive integer; anything else reads as unset, and a repo with neither is
  not gated.
  """
  @spec limits(Workspace.t() | map() | nil) :: %{String.t() => limits()}
  def limits(%Workspace{config: config}), do: limits(config)

  def limits(%{} = config) do
    case get_in(config, ["worker", "repos"]) do
      %{} = repos ->
        for {repo, %{} = block} <- repos,
            %{} = parsed <- [parse(Map.get(block, "ci_backpressure"))],
            into: %{},
            do: {to_string(repo), parsed}

      _ ->
        %{}
    end
  end

  def limits(_), do: %{}

  @doc "A `ci_backpressure` block as `t:limits/0`, or `nil` when it gates nothing."
  @spec parse(term()) :: limits() | nil
  def parse(%{} = block) do
    parsed = %{
      max_pending: positive(Map.get(block, "max_pending")),
      max_oldest_pending_min: positive(Map.get(block, "max_oldest_pending_min"))
    }

    if parsed.max_pending || parsed.max_oldest_pending_min, do: parsed
  end

  def parse(_), do: nil

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  @doc """
  Is the queue `signal` over `limits`? `:ok`, or `{:hold, detail}` where
  `detail` names the counts (`"6 pending, oldest 42m"`). An empty queue is
  never over a limit.
  """
  @spec evaluate(limits(), signal(), DateTime.t()) :: :ok | {:hold, String.t()}
  def evaluate(limits, %{pending: pending} = signal, %DateTime{} = now) when pending > 0 do
    if over_count?(limits, pending) or over_age?(limits, age_seconds(signal, now)) do
      {:hold, detail(pending, age_minutes(signal, now))}
    else
      :ok
    end
  end

  def evaluate(_limits, _signal, _now), do: :ok

  defp over_count?(%{max_pending: max}, pending), do: is_integer(max) and pending >= max

  defp over_age?(%{max_oldest_pending_min: max}, age) when is_integer(max) and is_integer(age),
    do: age > max * 60

  defp over_age?(_limits, _age), do: false

  defp age_seconds(%{oldest_at: %DateTime{} = oldest}, now),
    do: max(DateTime.diff(now, oldest, :second), 0)

  defp age_seconds(_signal, _now), do: nil

  defp age_minutes(signal, now) do
    case age_seconds(signal, now) do
      nil -> nil
      seconds -> div(seconds, 60)
    end
  end

  defp detail(pending, nil), do: "#{pending} pending"
  defp detail(pending, minutes), do: "#{pending} pending, oldest #{minutes}m"

  @doc """
  The holds for `issues`: `%{task_id => {:hold, detail}}` for every Ready
  ticket whose repo is gated by its workspace (among `workspaces`) and over
  its limits. Tickets past Ready, epics, P0 tickets and tickets with no repo
  get no entry, and neither does anything when the forge cannot be read.

  Options (all seams): `:poller` (`(workspace, repo -> {:ok, signal} |
  {:error, term})`, default `poll/2`), `:now`, `:interval_ms`, `:async`
  (default `true`; see `Cache`).
  """
  @spec holds([Workspace.t()], [map()], keyword()) :: %{String.t() => {:hold, String.t()}}
  def holds(workspaces, issues, opts \\ []) when is_list(workspaces) and is_list(issues) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    gates =
      for ws <- workspaces, {repo, limits} <- limits(ws), into: %{} do
        {{ws.id, repo}, {ws, limits}}
      end

    candidates = Enum.filter(issues, &(fresh_work?(&1) and gated?(gates, &1)))

    verdicts =
      candidates
      |> Enum.map(&{&1.workspace_id, &1.repo})
      |> Enum.uniq()
      |> Map.new(fn key -> {key, verdict(key, gates, now, opts)} end)

    for issue <- candidates,
        {:hold, _} = hold <- [Map.fetch!(verdicts, {issue.workspace_id, issue.repo})],
        into: %{},
        do: {issue.id, hold}
  end

  # A Ready ticket that is not P0. Anything already past Ready is a follow-up
  # of work the gate admitted (or an operator's own), and drains the queue.
  defp fresh_work?(issue) do
    Map.get(issue, :issue_type) != :epic and Lifecycle.state_of(issue) == :queued and
      Map.get(issue, :priority) != 0
  end

  defp gated?(gates, issue) do
    is_binary(Map.get(issue, :repo)) and Map.has_key?(gates, {issue.workspace_id, issue.repo})
  end

  defp verdict({_ws_id, repo} = key, gates, now, opts) do
    {ws, limits} = Map.fetch!(gates, key)
    decide(ws, repo, limits, now, opts)
  end

  # What the scheduler's gate says about one repo right now, and the one place a
  # decision is logged. A fresh dispatch waits (`{:hold, reason}`) while the queue
  # has not been read yet, and for the first failed polls; it fails open only when
  # the forge stays unreadable (`Cache.max_failures/0` polls in a row).
  defp decide(ws, repo, limits, now, opts) do
    gate = gate(read(ws, repo, opts), limits, now)
    note(ws, repo, gate)

    case gate do
      {:held, detail} -> {:hold, detail}
      {:waiting, reason} -> {:hold, reason}
      {:clear, _detail} -> :ok
      :open -> :ok
    end
  end

  defp gate({:ok, signal, _at}, limits, now) do
    detail = detail(signal.pending, age_minutes(signal, now))

    case evaluate(limits, signal, now) do
      :ok -> {:clear, detail}
      {:hold, detail} -> {:held, detail}
    end
  end

  defp gate({:error, failures}, _limits, _now) do
    if failures >= Cache.max_failures(),
      do: :open,
      else: {:waiting, "CI queue read failed, retrying (#{failures} of #{Cache.max_failures()})"}
  end

  defp gate(:unknown, _limits, _now), do: {:waiting, "awaiting a CI queue reading"}

  # A hold and its release are logged once each (per repo, on a change of state),
  # at info, naming the repo and the pending count and oldest age. Nothing is
  # logged for a repo that has only ever been clear.
  defp note(ws, repo, gate) do
    {state, detail} = state(gate)

    case Cache.note_state({ws.id, repo}, state) do
      :same -> :ok
      {:changed, previous} -> log_change(previous, state, "#{ws.name}/#{repo}", detail)
    end
  end

  defp state({:held, detail}), do: {:held, detail}
  defp state({:waiting, reason}), do: {:waiting, reason}
  defp state({:clear, detail}), do: {:clear, detail}
  defp state(:open), do: {:open, nil}

  defp log_change(_previous, :held, label, detail) do
    Logger.info("CiBackpressure: holding new dispatches for #{label}: CI saturated (#{detail})")
  end

  defp log_change(_previous, :waiting, label, reason) do
    Logger.info("CiBackpressure: holding new dispatches for #{label} for a tick: #{reason}")
  end

  defp log_change(previous, :clear, label, detail) when previous in [:held, :waiting, :open] do
    Logger.info("CiBackpressure: released #{label}: CI queue below its limits (#{detail})")
  end

  # The forge stayed unreadable: the cache has already warned; no second line.
  defp log_change(_previous, _state, _label, _detail), do: :ok

  defp read(ws, repo, opts) do
    poller = Keyword.get(opts, :poller, &poll/2)

    Cache.fetch(
      {ws.id, repo},
      Keyword.get(opts, :interval_ms, @interval_ms),
      fn -> poller.(ws, repo) end,
      async: Keyword.get(opts, :async, true),
      label: "#{ws.name}/#{repo}"
    )
  end

  @doc """
  Reads the CI queue of every gated repo in `workspaces` — whether or not a card
  is queued for it — so the cache is warm when the next card is promoted, and a
  hold or its release is logged when it happens rather than when a card next
  asks. Same options as `holds/3`. The `Refresher` calls it on a timer.
  """
  @spec refresh([Workspace.t()], keyword()) :: :ok
  def refresh(workspaces, opts \\ []) when is_list(workspaces) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    for ws <- workspaces, {repo, limits} <- limits(ws) do
      decide(ws, repo, limits, now, opts)
    end

    :ok
  end

  @doc """
  `repo`'s gate in `workspace` right now: `:ok`, or `{:hold, detail}` when its
  CI queue is over the configured limits. The speculative merge train
  (bd-6dyva0) asks it before testing more than its front car, so a saturated
  runner pool is not handed K pipelines at once. Reads the same cached poll as
  `holds/3` (same options), and fails open: an ungated repo, a poll not read
  yet or a failed one is `:ok` (the merge train is not a fresh dispatch, so it never
  waits for a reading).
  """
  @spec verdict(Workspace.t() | nil, String.t() | nil, keyword()) :: :ok | {:hold, String.t()}
  def verdict(workspace, repo, opts \\ [])

  def verdict(%Workspace{} = workspace, repo, opts) when is_binary(repo) do
    case Map.get(limits(workspace), repo) do
      nil ->
        :ok

      limits ->
        case read(workspace, repo, opts) do
          {:ok, signal, _at} ->
            evaluate(limits, signal, Keyword.get(opts, :now) || DateTime.utc_now())

          _unread ->
            :ok
        end
    end
  end

  def verdict(_workspace, _repo, _opts), do: :ok

  @doc """
  The per-repo status behind `scheduler_status` and `arb prime`: one map per
  gated repo with the cached `pending` count and `oldest_pending_min`, the
  thresholds and the hold `state` — `held`, `clear`, or `unknown` (not read
  yet, or the forge could not be). Takes the same options as `holds/3`.
  """
  @spec status([Workspace.t()], keyword()) :: [map()]
  def status(workspaces, opts \\ []) when is_list(workspaces) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    shared = shared_repos(workspaces)

    for ws <- workspaces, {repo, limits} <- limits(ws) do
      entry(ws, repo, limits, read(ws, repo, opts), now, repo in shared)
    end
    |> Enum.sort_by(&{&1.workspace, &1.repo})
  end

  defp shared_repos(workspaces) do
    workspaces
    |> Enum.flat_map(&Map.keys(limits(&1)))
    |> Enum.frequencies()
    |> Enum.filter(fn {_repo, n} -> n > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp entry(ws, repo, limits, outcome, now, shared?) do
    base = %{
      repo: repo,
      workspace: ws.name,
      workspace_id: ws.id,
      label: if(shared?, do: "#{ws.name}/#{repo}", else: repo),
      max_pending: limits.max_pending,
      max_oldest_pending_min: limits.max_oldest_pending_min,
      change_command:
        "arb config set worker.repos.#{repo}.ci_backpressure.max_pending N --workspace #{ws.name}"
    }

    case outcome do
      {:ok, signal, checked_at} ->
        verdict = evaluate(limits, signal, now)

        Map.merge(base, %{
          pending: signal.pending,
          oldest_pending_min: age_minutes(signal, now),
          state: if(verdict == :ok, do: "clear", else: "held"),
          detail: hold_detail(verdict),
          checked_at: checked_at
        })

      _unread ->
        Map.merge(base, %{
          pending: nil,
          oldest_pending_min: nil,
          state: "unknown",
          detail: nil,
          checked_at: nil
        })
    end
  end

  defp hold_detail({:hold, detail}), do: detail
  defp hold_detail(:ok), do: nil

  @doc """
  Read `repo`'s pending MR pipelines through the merger its workspace merges
  with (`Merger.ci_queue/0`): `{:ok, %{pending:, oldest_at:}}`, or
  `{:error, reason}` for a repo with no hosted forge, a merger without the
  callback, or a forge call that failed.
  """
  @spec poll(Workspace.t(), String.t()) :: {:ok, signal()} | {:error, term()}
  def poll(%Workspace{} = workspace, repo) when is_binary(repo) do
    adapter = Mergers.for_repo(workspace, repo)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :ci_queue, 0) do
      :ok = Mergers.prepare(workspace, repo: repo)
      prepare_slug(adapter, workspace, repo)
      adapter.ci_queue()
    else
      {:error, :ci_queue_unsupported}
    end
  end

  # A multi-repo GitHub workspace derives `owner/repo` from each repo's remote
  # rather than pinning it, so the adapter is told the slug (as PRPatrol does).
  defp prepare_slug(adapter, workspace, repo) do
    slug = Enum.find_value(ForgeRepos.list(workspace), &(&1.repo_key == repo && &1.slug))

    if adapter == Arbiter.Mergers.Github and is_binary(slug),
      do: adapter.prepare(Mergers.scope(workspace, repo), repo: slug),
      else: :ok
  end
end
