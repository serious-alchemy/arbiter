defmodule Arbiter.Quota.BurnReport do
  @moduledoc """
  The burn report (bd-cklotu): what the optional rolling-24h burn governor
  (`Arbiter.Quota.BurnGovernor`) would have done on the history we already have,
  so the operator can pick `daily_burn_cap` from data, or decide to have none.

  Per account, from its `quota_snapshots` 7d samples:

    * the **distribution of the historical 24 h burn** — p50 / p90 / p99 of the
      rolling-24h delta of the 7d window, on an hourly grid
      (`Arbiter.Quota.Burn.deltas/1`, with its window-reset baseline and its
      sparse-history `nil`s left out), and
    * for an account with a `daily_burn_cap` (or a cap given with `cap:`), the
      **"would have held"** count: the grid points at which the 24 h burn had
      reached the cap, out of all those with a reading, and when the first one was.

  This is the shadow half of the governor: nothing here holds anything, whatever
  the account's `daily_burn_cap_mode`. The same section is part of the admission
  shadow report once any account sets a
  cap. Read-only: `collect/1` reads, `build/2` is pure, `format/1` renders. Run it
  with `mix arbiter.burn_report` or, on a release,
  `bin/arbiter eval 'Arbiter.Release.burn_report()'`.

  A workspace's own (tighter) `daily_burn_cap` is not replayed here: the report is
  per account. Pass `cap:` to see a cap the account does not have yet.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Burn
  alias Arbiter.Quota.BurnGovernor
  alias Arbiter.Quota.QuotaSnapshot

  @default_days 30
  @window "7d"
  # Samples before `since` the first grid points need (the 24 h burn plus slack).
  @lookback_seconds 27 * 3600

  @type data :: %{
          since: DateTime.t(),
          until: DateTime.t(),
          snapshots: [map()],
          accounts: %{optional(String.t()) => ProviderAccount.t()}
        }

  @type report :: %{since: DateTime.t(), until: DateTime.t(), accounts: [map()]}

  @doc "Everything the report reads. Options: `:since` (default 30 days ago) and `:until` (default now)."
  @spec collect(keyword()) :: data()
  def collect(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)

    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.add(until, -@default_days * 86_400, :second)
      end)

    from = DateTime.add(since, -@lookback_seconds, :second)

    snapshots =
      QuotaSnapshot
      |> Ash.Query.filter(window == ^@window and captured_at >= ^from and captured_at <= ^until)
      |> Ash.Query.sort(captured_at: :asc)
      |> Ash.read!()

    %{since: since, until: until, snapshots: snapshots, accounts: read_accounts(snapshots)}
  end

  defp read_accounts(snapshots) do
    case snapshots |> Enum.map(& &1.provider_account_id) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        ProviderAccount |> Ash.Query.filter(id in ^ids) |> Ash.read!() |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  Summarise `t:data/0`. `opts[:cap]` replays that cap (a fraction in (0, 1]) on
  every account instead of its own `daily_burn_cap`.
  """
  @spec build(data(), keyword()) :: report()
  def build(%{since: since, until: until} = data, opts \\ []) do
    accounts =
      data.snapshots
      |> Enum.filter(&(&1.window == @window))
      |> Enum.group_by(& &1.provider_account_id)
      |> Enum.map(fn {id, rows} ->
        account_report(id, rows, Map.get(data.accounts, id), since, opts)
      end)
      |> Enum.sort_by(& &1.account)

    %{since: since, until: until, accounts: accounts}
  end

  defp account_report(id, rows, account, since, opts) do
    deltas =
      rows
      |> Enum.sort_by(& &1.captured_at, DateTime)
      |> Burn.deltas()
      |> Enum.reject(&(DateTime.compare(&1.at, since) == :lt))

    {cap, mode} = cap_and_mode(account, opts)

    %{
      account: label(id, account),
      account_id: id,
      samples: length(rows),
      deltas: deltas |> Enum.map(& &1.burn) |> Burn.percentiles(),
      cap: cap,
      mode: mode,
      would_hold: cap && would_hold(deltas, cap)
    }
  end

  defp cap_and_mode(account, opts) do
    case Keyword.get(opts, :cap) do
      cap when is_number(cap) -> {cap * 1.0, "shadow"}
      _ -> account_cap(account)
    end
  end

  defp account_cap(nil), do: {nil, nil}

  defp account_cap(account) do
    case BurnGovernor.cap(account) do
      nil -> {nil, nil}
      cap -> {cap, Atom.to_string(BurnGovernor.mode(account))}
    end
  end

  defp would_hold(deltas, cap) do
    held = Enum.filter(deltas, &(&1.burn >= cap))

    %{
      points: length(held),
      of: length(deltas),
      first_at: held |> List.first() |> then(&(&1 && &1.at)),
      last_at: held |> List.last() |> then(&(&1 && &1.at))
    }
  end

  defp label(_id, %ProviderAccount{provider: provider, slug: slug}), do: "#{provider}:#{slug}"
  defp label(id, _account), do: id

  @doc "The report as text: one block per account."
  @spec format(report()) :: String.t()
  def format(%{accounts: []}), do: "Burn governor\n  no 7d quota history"

  def format(report) do
    ["Burn governor (24h burn of the 7d window)" | Enum.map(report.accounts, &account_text/1)]
    |> Enum.join("\n")
  end

  defp account_text(%{deltas: %{n: 0}} = a),
    do: "  #{a.account}: no 24h reading (#{a.samples} samples, too sparse)"

  defp account_text(a) do
    d = a.deltas

    head =
      "  #{a.account}: 24h burn p50 #{pct(d.p50)}, p90 #{pct(d.p90)}, p99 #{pct(d.p99)} " <>
        "(#{d.n} hourly readings)"

    [head | cap_text(a)] |> Enum.join("\n")
  end

  defp cap_text(%{cap: nil}), do: []

  defp cap_text(%{cap: cap, mode: mode, would_hold: w}) do
    share = if w.of > 0, do: " (#{pct(w.points / w.of)})", else: ""

    first =
      if w.first_at, do: ", first #{Calendar.strftime(w.first_at, "%Y-%m-%d %H:%M")}Z", else: ""

    [
      "    cap #{pct(cap)} (#{mode}): would have held #{w.points} of #{w.of} readings#{share}#{first}"
    ]
  end

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100.0, decimals: 1)}%"
end
