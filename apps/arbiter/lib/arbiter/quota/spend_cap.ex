defmodule Arbiter.Quota.SpendCap do
  @moduledoc """
  A dollar spend cap per provider account over a day / week / month window
  (bd-a6grlr): "$20 a week on this account, and stop starting new work once it
  is reached", paced over the window the way the % quota thresholds are.

  ## Configuration

  Four keys in the account's `quota_config` (`Arbiter.Accounts.Fields`; `arb
  account set <ref> --spend-cap 20 --spend-window week --spend-mode paced`,
  MCP `account_set`, the Providers edit form):

    * `spend_cap` — the dollar cap. No cap, no behaviour.
    * `spend_window` — `day` | `week` | `month` (default `week`).
    * `spend_mode` — `flat` (default) allows the whole cap at any time;
      `paced` allows `cap x elapsed fraction of the window` by now.
    * `spend_metered` — whether the account's ledger costs are real spend
      (see below).

  ## Windows are fixed UTC calendar windows

  Not rolling: a day starts at 00:00 UTC, a **week starts Monday 00:00 UTC**,
  a month on the 1st at 00:00 UTC. The spend counted is everything the ledger
  holds for the account since the window opened, and the window "resets" when
  the next one opens. Fixed windows make "resets at ..." a statement an
  operator can plan around, and they are what the paced line needs: `elapsed`
  is a fraction of one named window. (A month is 28-31 days long; the line uses
  the actual length.)

  ## Only real metered spend counts

  The usage ledger prices every run (`cost_usd`), but for most accounts that
  price is notional: a Claude Max subscription's runs carry the API-equivalent
  price of work the subscription already paid for, agy and the Codex / Grok free
  tiers carry none. Counting those would hold a flat-rate account against a
  figure nobody is billed. So an account's spend counts only when it is
  `metered?/1`:

    1. `spend_metered: true | false` in `quota_config` says so explicitly;
    2. unset, the account is metered exactly when it has an active `api_key`
       credential (pay-per-token billing).

  A NULL `cost_usd` never counts either way. A cap on a non-metered account is
  accepted but reported as "no metered spend" (`status/2`, state
  `:no_metered_spend`) and never holds anything.

  ## The paced line is `Gate.pace/6`'s

  `verdict/3` asks `Arbiter.Quota.Gate.pace/6` for the `:spend` window with
  `utilization = spend / cap`, so the dollar line and the % lines share one
  definition (`Arbiter.Quota.Pace`): a paced ceiling is `max(0, elapsed)` of
  the cap, a flat one is the whole cap. The planning margin (design O8) and the
  look-ahead setting (design O1) are not in the gate yet — the gate holds the
  moment spend is past the line, which is the strict reading — and when they
  land in `Gate.pace/6` this cap inherits them without a second definition.

  ## Admission counts settled spend plus what is in flight

  `status/2` adds an **in-flight estimate** to the settled ledger spend: for each
  worker or admitted dispatch holding a slot on the account
  (`Arbiter.Accounts.Concurrency.holders/2`), the rest of its ticket's estimated
  cost (`Arbiter.Usage.Estimate` median less what the ticket has already spent,
  never below zero). The check runs under `Arbiter.Accounts.Admission`'s
  per-account lock, which also reserves the slot, so a burst of fresh dispatches
  each sees the earlier ones and cannot overshoot.

  ## Fresh dispatches only (the O2 distinction)

  Reaching the cap or the paced line holds only **fresh** dispatches
  (`fresh_dispatch?/2`): a ticket being started. Follow-ups on a ticket already
  started - ReviewGate reviewers and fix rounds, fix and conflict passes, resumes,
  re-dispatches of an In progress ticket - still run, so a ticket is never
  stranded half-finished. That is deliberately **not** a hard zero: the design's
  O2 (`docs/design/provider-dynamic-concurrency.md`) says follow-ups are held
  only by the hard rules (a provider refusing requests), and the spend cap is a
  scheduling rule, so in-flight tickets may finish and the account can end the
  window somewhat past the cap by exactly their remaining cost.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Quota.Gate
  alias Arbiter.Usage
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Estimate

  require Ash.Query
  require Logger

  # The fraction of the cap at which the operator is first paged.
  @warn_fraction 0.8

  @type window :: :day | :week | :month
  @type config :: %{usd: float(), window: window(), mode: :flat | :paced}

  @type status :: %{
          account: String.t() | nil,
          account_id: String.t() | nil,
          cap: float(),
          window: window(),
          mode: :flat | :paced,
          metered?: boolean(),
          state: :no_metered_spend | :ok | :warning | :holding,
          window_start: DateTime.t(),
          resets_at: DateTime.t(),
          elapsed: float() | nil,
          spent: float(),
          in_flight: float(),
          used: float(),
          allowed: float(),
          holding?: boolean(),
          reached?: boolean(),
          warn?: boolean(),
          phrase: String.t() | nil,
          wake_at: DateTime.t() | nil
        }

  @doc "The fraction of the cap at which the operator is first paged."
  @spec warn_fraction() :: float()
  def warn_fraction, do: @warn_fraction

  @doc """
  The cap configured on `account`, or `nil` (no cap, or one that does not
  parse). Window defaults to `:week`, mode to `:flat`.
  """
  @spec config(ProviderAccount.t() | nil) :: config() | nil
  def config(%{quota_config: %{} = quota}) do
    case parse_usd(Map.get(quota, "spend_cap")) do
      nil ->
        nil

      usd ->
        %{
          usd: usd,
          window: parse_window(Map.get(quota, "spend_window")),
          mode: parse_mode(Map.get(quota, "spend_mode"))
        }
    end
  end

  def config(_account), do: nil

  defp parse_usd(n) when is_number(n) and n > 0, do: n * 1.0

  defp parse_usd(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} when f > 0 -> f
      _ -> nil
    end
  end

  defp parse_usd(_), do: nil

  defp parse_window(w) when w in ["day", "week", "month"], do: String.to_existing_atom(w)
  defp parse_window(_), do: :week

  defp parse_mode("paced"), do: :paced
  defp parse_mode(_), do: :flat

  @doc """
  The fixed UTC window containing `now`: `%{start, reset_at, seconds}`. Day:
  00:00 UTC. Week: Monday 00:00 UTC. Month: the 1st, 00:00 UTC.
  """
  @spec bounds(window(), DateTime.t()) :: %{
          start: DateTime.t(),
          reset_at: DateTime.t(),
          seconds: pos_integer()
        }
  def bounds(window, %DateTime{} = now) do
    date = DateTime.to_date(now)

    {first, next} =
      case window do
        :day ->
          {date, Date.add(date, 1)}

        :week ->
          monday = Date.beginning_of_week(date, :monday)
          {monday, Date.add(monday, 7)}

        :month ->
          first = Date.beginning_of_month(date)
          {first, Date.add(Date.end_of_month(date), 1)}
      end

    start = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
    reset_at = DateTime.new!(next, ~T[00:00:00], "Etc/UTC")
    %{start: start, reset_at: reset_at, seconds: DateTime.diff(reset_at, start)}
  end

  @doc """
  Whether `account`'s ledger costs are real metered spend: `spend_metered`
  when set, else whether it has an active `api_key` credential. See the
  moduledoc.
  """
  @spec metered?(ProviderAccount.t() | nil) :: boolean()
  def metered?(%ProviderAccount{quota_config: %{"spend_metered" => flag}}) when is_boolean(flag),
    do: flag

  def metered?(%ProviderAccount{id: id}) when is_binary(id), do: api_key_credential?(id)
  def metered?(_account), do: false

  defp api_key_credential?(account_id) do
    kind = :api_key

    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and active == true and kind == ^kind)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Enum.any?()
  rescue
    _ -> false
  end

  @doc """
  Where `used` dollars stand against the cap at `now`, decided by
  `Arbiter.Quota.Gate.pace/6`'s `:spend` window.

  Returns the pace verdict (`:ok | :approaching | :holding | :sampling`), the
  `ceiling` as a fraction of the cap, `allowed` - that ceiling in dollars - and
  the window `elapsed` fraction. Nothing spent never holds.
  """
  @spec verdict(config(), number(), DateTime.t()) :: %{
          verdict: Arbiter.Quota.Pace.verdict(),
          mode: :paced | :flat | :exempt,
          ceiling: float(),
          allowed: float(),
          elapsed: float() | nil
        }
  def verdict(%{usd: cap, window: window, mode: mode}, used, %DateTime{} = now) do
    %{reset_at: reset_at, seconds: seconds} = bounds(window, now)
    policy = %ProviderAccount{quota_config: %{"spend_mode" => Atom.to_string(mode)}}

    pace =
      Gate.pace(policy, :spend, "spend_#{window}", used / cap, reset_at,
        now: now,
        window_seconds: seconds
      )

    %{
      verdict: if(used > 0, do: pace.verdict, else: :ok),
      mode: pace.mode,
      ceiling: pace.ceiling,
      allowed: pace.ceiling * cap,
      elapsed: pace.elapsed
    }
  end

  @doc """
  The cap's state for `account`, or `nil` when it has none.

  Options: `:now` (default `DateTime.utc_now/0`); `:exclude_task` - a task id
  whose own in-flight cost is left out (the ticket being admitted);
  `:in_flight` - a dollar figure that replaces the computed estimate (tests,
  and surfaces that must not read the worker registry).
  """
  @spec status(ProviderAccount.t() | nil, keyword()) :: status() | nil
  def status(account, opts \\ []) do
    case config(account) do
      nil -> nil
      cfg -> build_status(account, cfg, opts)
    end
  end

  defp build_status(account, cfg, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    %{start: start, reset_at: reset_at} = bounds(cfg.window, now)

    base = %{
      account: label(account),
      account_id: account.id,
      cap: cfg.usd,
      window: cfg.window,
      mode: cfg.mode,
      window_start: start,
      resets_at: reset_at
    }

    if metered?(account) do
      spent = settled(account, start)
      in_flight = Keyword.get_lazy(opts, :in_flight, fn -> in_flight(account, opts) end)
      metered_status(base, cfg, spent, in_flight, now)
    else
      Map.merge(base, %{
        metered?: false,
        state: :no_metered_spend,
        elapsed: nil,
        spent: 0.0,
        in_flight: 0.0,
        used: 0.0,
        allowed: cfg.usd,
        holding?: false,
        reached?: false,
        warn?: false,
        phrase: "spend cap $#{money(cfg.usd)}/#{cfg.window}: no metered spend",
        wake_at: nil
      })
    end
  end

  defp metered_status(base, cfg, spent, in_flight, now) do
    used = spent + in_flight
    v = verdict(cfg, used, now)
    reached? = used >= cfg.usd
    holding? = v.verdict == :holding
    warn? = used >= cfg.usd * @warn_fraction

    status =
      Map.merge(base, %{
        metered?: true,
        elapsed: v.elapsed,
        spent: spent,
        in_flight: in_flight,
        used: used,
        allowed: v.allowed,
        holding?: holding?,
        reached?: reached?,
        warn?: warn?,
        state:
          cond do
            holding? -> :holding
            warn? -> :warning
            true -> :ok
          end
      })

    status
    |> Map.put(:phrase, phrase(status))
    |> Map.put(:wake_at, wake_at(status, cfg))
  end

  defp label(%{provider: provider, slug: slug}) when not is_nil(provider) and is_binary(slug),
    do: "#{provider}:#{slug}"

  defp label(_account), do: nil

  defp settled(%ProviderAccount{id: id}, start) when is_binary(id) do
    Usage.priced_spend_since(id, start)
  end

  defp settled(_account, _start), do: 0.0

  @doc """
  The estimated remaining cost of the work in flight on `account`: for each
  worker or admitted dispatch holding a slot, its ticket's estimated median
  less what the ticket has already spent, never below zero. `0.0` when nothing
  is in flight or there is no estimate to go on. Fails to `0.0` - an unreadable
  estimate must not stop dispatch.

  Options: `:exclude_task` (see `status/2`), `:holders` (registry keys,
  replacing the registry read) and `:estimate_fun` (task id -> median or `nil`).
  """
  @spec in_flight(ProviderAccount.t(), keyword()) :: float()
  def in_flight(%ProviderAccount{} = account, opts \\ []) do
    ids =
      opts
      |> Keyword.get_lazy(:holders, fn ->
        Concurrency.holders(account, exclude_task: Keyword.get(opts, :exclude_task))
      end)
      |> Enum.map(&Estimate.fold_task_id/1)
      |> Enum.reject(&(&1 == Keyword.get(opts, :exclude_task)))
      |> Enum.uniq()

    if ids == [] do
      0.0
    else
      spent = Budget.spend_by_task(ids)
      estimate = Keyword.get_lazy(opts, :estimate_fun, fn -> estimate_fun() end)

      ids
      |> Enum.map(fn id ->
        case estimate.(id) do
          median when is_number(median) -> max(median - Map.get(spent, id, 0.0), 0.0)
          _ -> 0.0
        end
      end)
      |> Enum.sum()
      |> Kernel.*(1.0)
    end
  rescue
    e ->
      Logger.warning("SpendCap.in_flight failed: #{Exception.message(e)}")
      0.0
  end

  defp estimate_fun do
    sample = Estimate.sample()

    fn id ->
      case Estimate.for_issue(id, sample: sample) do
        %{median: median} -> median
        _ -> nil
      end
    end
  end

  @doc """
  `:ok` or `{:hold, reason}` for a fresh dispatch of `task` onto `account`.

  The reason is a map the dispatch queue stores and shows: `gate: :spend`, the
  operator `phrase`, the `window`, the `account`, the figures and `wake_at`,
  when the hold next needs looking at (the reset for a flat cap, the moment the
  paced line reaches the spend for a paced one). Options as `status/2`; the
  task's id is excluded from the in-flight estimate.
  """
  @spec check(ProviderAccount.t() | nil, map() | nil, keyword()) :: :ok | {:hold, map()}
  def check(account, task, opts \\ []) do
    opts =
      case task do
        %{id: id} when is_binary(id) -> Keyword.put_new(opts, :exclude_task, id)
        _ -> opts
      end

    case status(account, opts) do
      %{holding?: true} = status -> {:hold, reason(status)}
      _ -> :ok
    end
  end

  @doc "The hold reason map for a holding `status/2` (see `check/3`)."
  @spec reason(status()) :: map()
  def reason(status) do
    %{
      gate: :spend,
      signal: :spend,
      phrase: status.phrase,
      window: "spend_#{status.window}",
      account: status.account,
      cap: status.cap,
      used: status.used,
      allowed: status.allowed,
      mode: status.mode,
      resets_at: status.resets_at,
      wake_at: status.wake_at
    }
  end

  @doc """
  Is this dispatch of `task` a fresh one - a ticket being started - rather than
  a follow-up on work already under way? Only fresh dispatches are held by the
  spend cap. Not fresh: a ticket already In progress, a resume, a review, and
  any ReviewGate / fix-pass / conflict-pass synthetic id.
  """
  @spec fresh_dispatch?(map(), keyword()) :: boolean()
  def fresh_dispatch?(%{id: id, state: state}, opts) do
    state != :active and
      Keyword.get(opts, :resume) != true and
      Keyword.get(opts, :review) != true and
      Estimate.fold_task_id(id) == id
  end

  @doc """
  Whether an operator forced this dispatch past the quota gate
  (`arb dispatch --force-quota`: `:skip_quota_gate` plus the actor stamped on
  it). The drain's own replay sets `:skip_quota_gate` without an actor and is
  not a bypass.
  """
  @spec bypassed?(keyword()) :: boolean()
  def bypassed?(opts) do
    Keyword.get(opts, :skip_quota_gate) == true and
      not is_nil(Keyword.get(opts, :quota_bypass_actor))
  end

  # ---- wording -------------------------------------------------------------

  # 'spend cap $X/week reached ($Y spent), resets <ts>' once the cap itself is
  # reached; 'spend pace: $Y of $Z allowed by now' while a paced line is.
  defp phrase(%{holding?: false}), do: nil

  defp phrase(%{reached?: true} = s) do
    "spend cap $#{money(s.cap)}/#{s.window} reached (#{spent_text(s)}), resets #{ts(s.resets_at)}"
  end

  defp phrase(s) do
    "spend pace: $#{money(s.used)} of $#{money(s.allowed)} allowed by now " <>
      "($#{money(s.cap)}/#{s.window} cap, #{percent(s.elapsed)} of the window elapsed)"
  end

  defp spent_text(%{in_flight: in_flight} = s) when in_flight > 0.005,
    do: "$#{money(s.spent)} spent + ~$#{money(in_flight)} in flight"

  defp spent_text(s), do: "$#{money(s.used)} spent"

  defp wake_at(%{holding?: false}, _cfg), do: nil
  defp wake_at(%{reached?: true} = s, _cfg), do: s.resets_at
  defp wake_at(%{mode: :flat} = s, _cfg), do: s.resets_at

  # Paced: the line reaches `used` at start + used/cap of the window.
  defp wake_at(s, cfg) do
    %{seconds: seconds} = bounds(cfg.window, s.window_start)
    at = DateTime.add(s.window_start, round(s.used / s.cap * seconds), :second)
    if DateTime.before?(at, s.resets_at), do: at, else: s.resets_at
  end

  @doc "Dollars as `12.30` (no `$`)."
  @spec money(number()) :: String.t()
  def money(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp percent(n) when is_number(n), do: "#{round(n * 100)}%"
  defp percent(_), do: "-"

  defp ts(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  @doc """
  The wire shape of a `status/2` for `arb account show`, `quota_get` and the
  scheduler status: string keys, ISO-8601 times, `nil` for no cap.
  """
  @spec to_map(status() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(status) do
    %{
      "cap_usd" => status.cap,
      "window" => Atom.to_string(status.window),
      "mode" => Atom.to_string(status.mode),
      "metered" => status.metered?,
      "state" => Atom.to_string(status.state),
      "spent_usd" => round2(status.spent),
      "in_flight_usd" => round2(status.in_flight),
      "used_usd" => round2(status.used),
      "allowed_usd" => round2(status.allowed),
      "elapsed" => status.elapsed && Float.round(status.elapsed, 4),
      "window_start" => DateTime.to_iso8601(status.window_start),
      "resets_at" => DateTime.to_iso8601(status.resets_at),
      "holding" => status.holding?,
      "reached" => status.reached?,
      "reason" => status.phrase
    }
  end

  defp round2(n), do: Float.round(n * 1.0, 2)
end
