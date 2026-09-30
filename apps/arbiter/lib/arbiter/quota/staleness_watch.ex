defmodule Arbiter.Quota.StalenessWatch do
  @moduledoc """
  Alerts when Claude quota accounting has gone blind (bd-2wnkoq): an operator
  alert keyed on the persisted quota snapshot's **state** — how old it is —
  rather than on any component reporting a failure.

  ## Why a separate check

  A stale snapshot silences the gate by design: `Arbiter.Quota.Gate` fails the
  5h window open once `captured_at` is older than it trusts, and 5h overage
  detection goes with it (`Arbiter.Quota.Gate.in_overage?/2` cannot see a cap
  crossed after the last reading). That is correct in isolation and dangerous
  in aggregate: every other quota alarm — `quota_poll_failing`,
  `operator_login_lapsed`, `quota_grant_failing` — is raised by
  `Arbiter.Quota.CloudProbe` or `Arbiter.Quota.GrantRefresher` *reporting a
  failure*. When the thing that should report stops reporting, nothing fires;
  one expired token once left the fleet dispatching for nineteen hours on a
  snapshot nobody was refreshing, overage undetected and unalerted.

  So this runs on its own timer, reads the snapshot straight from the table,
  and never touches CloudProbe's poll or failure path. It alerts on what the
  operator has to act on — the accounting is blind — whatever the cause, and
  keeps alerting while it stays true.

  ## What it checks

  Every `:interval_ms` (default one minute) it reads the `AnthropicQuota`
  snapshot of every Claude provider account a workspace is metered under —
  the accounts CloudProbe polls — and sorts each into one of:

    * **no snapshot yet** — no row, or a row the poll never wrote a 5h figure
      into (`captured_at` nil). Benign: a fresh install, or one that has never
      had a working Claude credential. No alert.
    * **fresh** — `captured_at` younger than the threshold.
    * **stale** — `captured_at` at least the threshold old: raises (or, while
      one is active, refreshes) the account's
      `Arbiter.Messages.CoordinatorNotifier.quota_snapshot_stale/2` alert.

  After each check `CoordinatorNotifier.quota_snapshot_recovered/1` clears the
  alert of every account that is no longer stale — fresh again, no snapshot,
  or no longer linked to a workspace. So the alert is edge-triggered and
  self-clearing: one per account per stale episode, cleared by the first
  check that sees a fresh snapshot, and a later lapse opens a new one. A check
  that cannot read the snapshots raises and clears nothing.

  ## Threshold

  `config :arbiter, :quota, stale_alert_threshold_seconds:` — default
  #{1_800} s (30 minutes), comfortably past the gate's own 1200 s margin for a
  polled row, so an ordinary 429 (which costs two polls, see
  `Arbiter.Quota.OAuthUsage`) never alerts while a sustained outage does
  within half an hour.

  The effective threshold is never below
  `Arbiter.Quota.Gate.staleness_threshold_seconds/1` for the snapshot's own
  `capture_source` (see `threshold_seconds/1`): the alert says the 5h gate is
  failing open, and below that age it is not.

  ## Timing

  The first check runs `:initial_delay_ms` after start — by default one
  `Arbiter.Quota.CloudProbe.interval_ms/0` plus a minute — so a server coming
  back from a long downtime gives the probe its first poll before the
  snapshot is judged, rather than flashing an alert that the next poll
  clears. The first check logs a one-line summary at `info`; a snapshot going
  stale logs a warning, and one recovering logs at `info`.

  ## Configuration

  `config :arbiter, :quota_staleness_watch` — `:enabled` (default `true`,
  `false` in test), `:interval_ms`, `:initial_delay_ms`. Tests also pass
  `:read_fun`, replacing `read_claude_snapshots/0`.
  """

  use GenServer
  require Ash.Query
  require Logger

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CloudProbe
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @default_interval_ms 60_000
  @default_threshold_seconds 1_800

  @typedoc "One Claude account the watch reads, with its workspaces and snapshot."
  @type entry :: %{
          account: ProviderAccount.t(),
          workspaces: [Workspace.t()],
          quota: AnthropicQuota.t() | nil
        }

  @typedoc "What one check found for one account."
  @type result :: %{
          required(:status) => :no_snapshot | :fresh | :stale,
          required(:account) => String.t(),
          optional(:age_seconds) => non_neg_integer(),
          optional(:threshold_seconds) => pos_integer()
        }

  defmodule State do
    @moduledoc false
    defstruct [:enabled, :interval_ms, :read_fun, checks: 0, last_check_at: nil, accounts: %{}]
  end

  # ---- public API --------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one check now, in the watch's own process, and return what it found
  (`iex`, tests) — `{:ok, %{account_id => result}}`, or `{:error, reason}`
  when the snapshots could not be read.
  """
  @spec check_now(GenServer.server()) :: {:ok, %{String.t() => result()}} | {:error, term()}
  def check_now(server \\ __MODULE__), do: GenServer.call(server, :check, 60_000)

  @doc """
  The watch's state: `%{enabled:, interval_ms:, checks:, last_check_at:,
  accounts: %{account_id => result}}` — `accounts` as of the last check.
  """
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc """
  The age, in seconds, at which a snapshot written by `capture_source` alerts:
  the configured `:stale_alert_threshold_seconds` (default
  #{@default_threshold_seconds}), raised to
  `Arbiter.Quota.Gate.staleness_threshold_seconds/1` for that source when it
  is lower — the alert never fires while the gate still trusts the snapshot.
  """
  @spec threshold_seconds(String.t() | nil) :: pos_integer()
  def threshold_seconds(capture_source) do
    max(configured_threshold_seconds(), Gate.staleness_threshold_seconds(capture_source))
  end

  @doc """
  Check every Claude account's snapshot and raise or clear the staleness
  alerts accordingly (see the moduledoc). Options: `:now` (default
  `DateTime.utc_now/0`), `:read_fun` (default `read_claude_snapshots/0`).
  """
  @spec check(keyword()) :: {:ok, %{String.t() => result()}} | {:error, term()}
  def check(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    read_fun = Keyword.get(opts, :read_fun, &read_claude_snapshots/0)

    case read_fun.() do
      {:ok, entries} ->
        results = Map.new(entries, &{&1.account.id, assess(&1, now)})

        for %{account: %{id: id}} = entry <- entries, results[id].status == :stale do
          raise_stale(entry, results[id], now)
        end

        CoordinatorNotifier.quota_snapshot_recovered(
          for({id, %{status: :stale}} <- results, do: id)
        )

        {:ok, results}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Every Claude provider account a workspace is metered under, with those
  workspaces (sorted by name) and the account's persisted snapshot, or `nil`
  when it has none. `{:error, reason}` when either read fails.
  """
  @spec read_claude_snapshots() :: {:ok, [entry()]} | {:error, term()}
  def read_claude_snapshots do
    with {:ok, links} <- read_claude_links(),
         accounts = group_by_account(links),
         {:ok, quotas} <- read_quotas(Map.keys(accounts)) do
      {:ok,
       for {id, {account, workspaces}} <- accounts do
         %{account: account, workspaces: workspaces, quota: Map.get(quotas, id)}
       end}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # ---- GenServer ---------------------------------------------------------

  @impl true
  def init(opts) do
    state = %State{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      read_fun: Keyword.get(opts, :read_fun, &read_claude_snapshots/0)
    }

    if state.enabled do
      initial_delay_ms = cfg(:initial_delay_ms, opts, CloudProbe.interval_ms() + 60_000)
      schedule(initial_delay_ms)

      Logger.info(
        "Arbiter.Quota.StalenessWatch: watching the Claude quota snapshot — first check in " <>
          "#{div(initial_delay_ms, 1_000)}s, then every #{div(state.interval_ms, 1_000)}s; " <>
          "alerting once a polled snapshot is #{threshold_seconds("oauth_poll")}s old"
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, %State{} = state) do
    {reply, state} = run_check(state)
    {:reply, reply, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply,
     %{
       enabled: state.enabled,
       interval_ms: state.interval_ms,
       checks: state.checks,
       last_check_at: state.last_check_at,
       accounts: state.accounts
     }, state}
  end

  @impl true
  def handle_info(:check, %State{} = state) do
    state = if state.enabled, do: elem(run_check(state), 1), else: state
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- checks ------------------------------------------------------------

  defp run_check(%State{} = state) do
    now = DateTime.utc_now()

    case check(now: now, read_fun: state.read_fun) do
      {:ok, results} = reply ->
        log_check(state, results)
        {reply, %{state | checks: state.checks + 1, last_check_at: now, accounts: results}}

      {:error, reason} = reply ->
        Logger.warning(
          "Arbiter.Quota.StalenessWatch: could not read the Claude quota snapshots " <>
            "(#{inspect(reason)}) — no staleness alert raised or cleared this check"
        )

        {reply, %{state | checks: state.checks + 1, last_check_at: now}}
    end
  rescue
    e ->
      Logger.warning("Arbiter.Quota.StalenessWatch: check raised: #{Exception.message(e)}")
      {{:error, {:exception, Exception.message(e)}}, state}
  end

  defp assess(%{account: account, quota: %AnthropicQuota{captured_at: %DateTime{} = at} = q}, now) do
    age = max(DateTime.diff(now, at, :second), 0)
    threshold = threshold_seconds(q.capture_source)

    %{
      status: if(age >= threshold, do: :stale, else: :fresh),
      account: account_label(account),
      age_seconds: age,
      threshold_seconds: threshold
    }
  end

  defp assess(%{account: account}, _now),
    do: %{status: :no_snapshot, account: account_label(account)}

  # One account's alert failing to build must not cost the others theirs, nor
  # the clearing that follows — so each is raised on its own.
  defp raise_stale(%{workspaces: [workspace | _]} = entry, result, now) do
    CoordinatorNotifier.quota_snapshot_stale(
      %{workspace_id: workspace.id},
      stale_info(entry, result, now)
    )
  rescue
    e ->
      Logger.warning(
        "Arbiter.Quota.StalenessWatch: could not raise the stale-snapshot alert for " <>
          "#{result.account}: #{Exception.message(e)}"
      )
  end

  defp raise_stale(_entry, _result, _now), do: :ok

  defp stale_info(%{account: account, workspaces: workspaces, quota: q}, result, now) do
    snapshot = Snapshot.normalize(q)

    %{
      account_id: account.id,
      account: result.account,
      workspaces: Enum.map(workspaces, & &1.name),
      captured_at: q.captured_at,
      age_seconds: result.age_seconds,
      threshold_seconds: result.threshold_seconds,
      capture_source: q.capture_source,
      last_poll_at: later_than(q.oauth_captured_at, q.captured_at),
      cap_reached_until: if(Gate.primary_in_overage?(snapshot), do: snapshot.reset_at),
      long_window: long_window(snapshot, account, workspaces, now)
    }
  end

  defp later_than(%DateTime{} = at, %DateTime{} = than),
    do: if(DateTime.after?(at, than), do: at)

  defp later_than(_at, _than), do: nil

  defp long_window(%Snapshot{secondary_window_label: nil}, _account, _workspaces, _now), do: nil

  defp long_window(%Snapshot{} = s, account, workspaces, now) do
    %{
      label: s.secondary_window_label,
      utilization: s.secondary_utilization,
      status: s.secondary_status,
      reset_at: s.secondary_reset_at,
      reset_in_seconds: seconds_until(s.secondary_reset_at, now),
      rolled?: Gate.long_window_stale?(s),
      hold: long_hold(s, account, workspaces, now)
    }
  end

  defp seconds_until(%DateTime{} = at, now), do: max(DateTime.diff(at, now, :second), 0)
  defp seconds_until(_at, _now), do: nil

  # Which workspaces the long window is holding right now, judged exactly as
  # the gate judges them (`min(account, workspace)` thresholds). A `:continue`
  # workspace never holds. The snapshot is stale, so its primary rules are
  # already dropped and any binding left is the long window's.
  defp long_hold(%Snapshot{} = s, account, workspaces, now) do
    held =
      for ws <- workspaces,
          not Arbiter.Quota.continue_mode?(ws),
          %{window: window} <- [Gate.gating_window(s, {account, ws}, now: now)],
          window == s.secondary_window_label,
          do: {ws.name, Gate.hold_phrase(s, {account, ws}, now: now)}

    case held do
      [] -> nil
      [{_name, reason} | _] -> %{workspaces: Enum.map(held, &elem(&1, 0)), reason: reason}
    end
  end

  # ---- reads -------------------------------------------------------------

  defp read_claude_links do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider == :claude)
    |> Ash.Query.load([:workspace, :provider_account])
    |> Ash.read()
  end

  defp group_by_account(links) do
    links
    |> Enum.reject(&(is_nil(&1.workspace) or is_nil(&1.provider_account)))
    |> Enum.group_by(& &1.provider_account_id)
    |> Map.new(fn {id, [first | _] = account_links} ->
      {id,
       {first.provider_account,
        account_links |> Enum.map(& &1.workspace) |> Enum.sort_by(& &1.name)}}
    end)
  end

  defp read_quotas([]), do: {:ok, %{}}

  defp read_quotas(account_ids) do
    AnthropicQuota
    |> Ash.Query.filter(provider == "claude" and provider_account_id in ^account_ids)
    |> Ash.read()
    |> case do
      {:ok, rows} -> {:ok, Map.new(rows, &{&1.provider_account_id, &1})}
      {:error, _reason} = error -> error
    end
  end

  # ---- logging -----------------------------------------------------------

  defp log_check(%State{} = state, results) do
    if state.checks == 0 do
      Logger.info("Arbiter.Quota.StalenessWatch: first check — #{summary(results)}")
    else
      Logger.debug("Arbiter.Quota.StalenessWatch: #{summary(results)}")
    end

    for {id, result} <- results, do: log_transition(Map.get(state.accounts, id), result)
    :ok
  end

  defp log_transition(%{status: :stale}, %{status: :stale}), do: :ok

  defp log_transition(_previous, %{status: :stale} = result) do
    Logger.warning(
      "Arbiter.Quota.StalenessWatch: #{result.account} quota snapshot is " <>
        "#{result.age_seconds}s old — quota accounting is blind; alert raised"
    )
  end

  defp log_transition(%{status: :stale}, result) do
    Logger.info(
      "Arbiter.Quota.StalenessWatch: #{result.account} quota snapshot is " <>
        "#{describe_status(result)} — alert cleared"
    )
  end

  defp log_transition(_previous, _result), do: :ok

  defp summary(results) when map_size(results) == 0,
    do: "no Claude account is linked to a workspace; nothing to watch"

  defp summary(results) do
    results
    |> Map.values()
    |> Enum.map_join("; ", &"#{&1.account}: #{describe_status(&1)}")
  end

  defp describe_status(%{status: :no_snapshot}), do: "no snapshot yet"

  defp describe_status(%{status: status, age_seconds: age, threshold_seconds: threshold}),
    do: "#{status}, #{age}s old (alerts at #{threshold}s)"

  # ---- helpers -----------------------------------------------------------

  defp account_label(%ProviderAccount{slug: slug}) when is_binary(slug), do: "claude:#{slug}"
  defp account_label(%ProviderAccount{id: id}), do: "claude:#{id}"

  defp configured_threshold_seconds do
    case Application.get_env(:arbiter, :quota, [])[:stale_alert_threshold_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_threshold_seconds
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :check, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case Application.get_env(:arbiter, :quota_staleness_watch, []) do
          kw when is_list(kw) -> Keyword.get(kw, key, default)
          _ -> default
        end
    end
  end
end
