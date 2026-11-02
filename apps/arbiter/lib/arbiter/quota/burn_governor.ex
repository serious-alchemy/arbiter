defmodule Arbiter.Quota.BurnGovernor do
  @moduledoc """
  The optional rolling-24h burn governor (bd-cklotu): with the 5h window gone,
  Claude has no short-horizon brake, and this is one the operator may switch on.
  Off unless a `daily_burn_cap` is set.

  ## Settings

    * `daily_burn_cap` — a fraction in (0, 1] of the 7d window that may be used
      in any rolling 24 h (`Arbiter.Quota.Burn`). Account `quota_config`, and a
      workspace's `quota` map may only tighten it: `min(account, workspace)`.
    * `daily_burn_cap_mode` — `shadow` (the default) or `enforce`. `shadow`
      holds nothing: the cap is only measured (`would_hold/4`, and the
      `burn_report` / admission shadow report replay it over the history).
      `enforce` makes it a hold. Either side saying `enforce` enforces it.

  ## Where it holds (`enforce`)

    * **Gate** — a flat rule: `burn_24h >= cap` holds the dispatch
      (`binding/4`), ranked after the 7d rules. It is a utilization rule, so
      `pace: false` (admission `enforce`) leaves it out and
    * **Budget** — adds a `24h` window entry (the provider concurrency budget, DC3) whose
      line is the cap and whose draw is the 7d window's `ρ`, so the seat count
      shrinks before the cap is reached (`window/3`).

  Both honour the P0 pace exemption (`Arbiter.Quota.Gate.pace_exempt?/2`): an
  exempt dispatch is never held on the burn.

  A `nil` or stale `burn_24h` (sparse history, or the poll stopped) is "no
  reading" and never holds.
  """

  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @modes ~w[shadow enforce]
  # The poll runs every few minutes; an hour-old burn is a dead poll.
  @max_age_seconds 3600

  @doc "Valid `daily_burn_cap_mode` value strings (the first is the default)."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "The effective `daily_burn_cap` under `policy`, a fraction, or `nil` (off)."
  @spec cap(Gate.policy()) :: float() | nil
  def cap(policy) do
    {account, workspace} = Gate.policy_pair(policy)

    [account_config(account)["daily_burn_cap"], ws_quota(workspace)["daily_burn_cap"]]
    |> Enum.map(&fraction/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  @doc "`:enforce` when either side enforces, else `:shadow`."
  @spec mode(Gate.policy()) :: :shadow | :enforce
  def mode(policy) do
    {account, workspace} = Gate.policy_pair(policy)

    if "enforce" in [
         account_config(account)["daily_burn_cap_mode"],
         ws_quota(workspace)["daily_burn_cap_mode"]
       ],
       do: :enforce,
       else: :shadow
  end

  @doc """
  The snapshot's burn when it can be trusted at `now`: a number computed no
  longer than an hour ago, on a long window that is itself fresh. Else `nil`.
  """
  @spec reading(Snapshot.t(), DateTime.t()) :: float() | nil
  def reading(%Snapshot{burn_24h: burn, burn_24h_at: %DateTime{} = at} = s, now)
      when is_number(burn) do
    if DateTime.diff(now, at) <= @max_age_seconds and not Gate.long_window_stale?(s, now),
      do: burn * 1.0
  end

  def reading(_snapshot, _now), do: nil

  @doc """
  The hold the Gate applies under `enforce`: a binding map (`window: "24h"`,
  `signal: :burn`) when the burn has reached the cap and `priority` is not
  exempt, else `nil`.
  """
  @spec binding(Snapshot.t(), Gate.policy(), DateTime.t(), integer() | nil) :: map() | nil
  def binding(%Snapshot{} = s, policy, now, priority) do
    with :enforce <- mode(policy),
         %{burn: burn, cap: cap} = verdict <- verdict(s, policy, now, priority),
         true <- verdict.holding? do
      %{
        provider: s.provider,
        window: "24h",
        signal: :burn,
        status: nil,
        utilization: burn,
        threshold: cap
      }
    else
      _ -> nil
    end
  end

  @doc """
  What `enforce` would hold, while the mode is `shadow`: `%{burn, cap, mode:
  :shadow}` when the burn has reached the cap for a non-exempt `priority`, else
  `nil`. This is the "would have held" record.
  """
  @spec would_hold(Snapshot.t(), Gate.policy(), DateTime.t(), integer() | nil) :: map() | nil
  def would_hold(%Snapshot{} = s, policy, now, priority) do
    with :shadow <- mode(policy),
         %{holding?: true} = verdict <- verdict(s, policy, now, priority) do
      %{burn: verdict.burn, cap: verdict.cap, mode: :shadow}
    else
      _ -> nil
    end
  end

  @doc """
  The Budget's `24h` window inputs under `enforce`: `%{used: burn, cap: cap}`,
  or `nil` when off, in `shadow`, unmeasured, or `priority` is exempt (the
  exempt budget leaves the window out, as the P0 exemption lifts the line).
  """
  @spec window(Snapshot.t() | nil, Gate.policy(), DateTime.t()) ::
          %{used: float(), cap: float()} | nil
  def window(%Snapshot{} = s, policy, now) do
    with :enforce <- mode(policy),
         cap when is_float(cap) <- cap(policy),
         burn when is_float(burn) <- reading(s, now) do
      %{used: burn, cap: cap}
    else
      _ -> nil
    end
  end

  def window(_snapshot, _policy, _now), do: nil

  defp verdict(%Snapshot{} = s, policy, now, priority) do
    with cap when is_float(cap) <- cap(policy),
         burn when is_float(burn) <- reading(s, now) do
      %{burn: burn, cap: cap, holding?: burn >= cap and not Gate.pace_exempt?(policy, priority)}
    else
      _ -> nil
    end
  end

  defp account_config(%{quota_config: config}) when is_map(config), do: config
  defp account_config(_), do: %{}

  defp ws_quota(%{config: %{"quota" => %{} = quota}}), do: quota
  defp ws_quota(_), do: %{}

  defp fraction(n) when is_number(n) and n > 0 and n <= 1, do: n * 1.0

  defp fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} when f > 0 and f <= 1 -> f
      _ -> nil
    end
  end

  defp fraction(_), do: nil
end
