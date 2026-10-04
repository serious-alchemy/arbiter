defmodule Arbiter.Quota.CodexPlanWindows do
  @moduledoc """
  Per-plan Codex window lengths (bd-afvsnc), the fallback `Arbiter.Quota.Gate`
  paces against when `wham/usage` did not report a window's length.

  Window shape and length differ by plan tier, so there is no global default:
  the length is looked up per `{plan, window}` and an unrecognized plan — or a
  window the plan does not have — resolves to `nil`, which means **pacing off**
  for that window (the gate falls back to its flat ceiling), never a guess.

  A length the API itself reported (`limit_window_seconds`, stored on the
  `CodexQuota` row) always outranks this table; the table only covers rows that
  carry no reported length.

  ## Defaults

    * `"free"` — one `:session` window of 43 200 minutes (30 days), no weekly
      window. **Unconfirmed**: the 30-day figure is inferred from a `reset_at`
      14 days out on a 27%-used reading and is not documented by OpenAI. The
      reported length wins whenever the API supplies it; override the table if
      the real length turns out to differ.
    * `"plus"`, `"pro"`, `"team"` — a 5h `:session` (300 min) plus a `:weekly`
      (10 080 min) window.

  Override or extend per install:

      config :arbiter, :quota,
        codex_plan_windows: %{"free" => %{session: 43_200}, "enterprise" => %{session: 300}}

  Entries merge over the defaults per plan; a `nil` / non-positive length
  switches a default window off.
  """

  @defaults %{
    "free" => %{session: 43_200},
    "plus" => %{session: 300, weekly: 10_080},
    "pro" => %{session: 300, weekly: 10_080},
    "team" => %{session: 300, weekly: 10_080}
  }

  @type window :: :session | :weekly

  @doc "The built-in table, before any app-env override."
  @spec defaults() :: %{String.t() => %{optional(window()) => pos_integer()}}
  def defaults, do: @defaults

  @doc """
  Length in minutes of `window` on `plan`, or `nil` when the plan is unknown,
  `nil`, or has no such window.
  """
  @spec minutes(String.t() | nil, window()) :: pos_integer() | nil
  def minutes(plan, window) when is_binary(plan) and window in [:session, :weekly] do
    case table() |> Map.get(String.downcase(String.trim(plan))) |> window_length(window) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  def minutes(_plan, _window), do: nil

  @doc "Whether `plan` appears in the table at all."
  @spec known_plan?(String.t() | nil) :: boolean()
  def known_plan?(plan) when is_binary(plan),
    do: Map.has_key?(table(), String.downcase(String.trim(plan)))

  def known_plan?(_), do: false

  defp window_length(%{} = windows, window), do: Map.get(windows, window)
  defp window_length(_, _), do: nil

  defp table do
    overrides =
      case Application.get_env(:arbiter, :quota, [])[:codex_plan_windows] do
        %{} = m -> Map.new(m, fn {plan, w} -> {String.downcase(to_string(plan)), w} end)
        _ -> %{}
      end

    Map.merge(@defaults, overrides, fn _plan, base, over when is_map(over) ->
      Map.merge(base, over)
    end)
  end
end
