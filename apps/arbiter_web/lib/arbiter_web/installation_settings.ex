defmodule ArbiterWeb.InstallationSettings do
  @moduledoc """
  The dashboard's one code path for the install-wide settings: parsing what a
  form posted, validating and saving it, and flipping the scheduler's autopilot.

  `/settings` (`ArbiterWeb.SettingsLive`) and the board toolbar
  (`ArbiterWeb.BoardLive`) both call in here, so the two surfaces cannot
  disagree about what a valid value is or how it is stored. The validation and
  persistence themselves are `Arbiter.Settings.Registry`'s — the same ones REST,
  the CLI and MCP use — this module only adds the form-input handling on top.

  A change on any surface is announced on `Arbiter.Settings.topic/0` (and the
  autopilot's own `Arbiter.Board.Autopilot.topic/0`), which both pages
  subscribe to, so one shows the other's change without a manual refresh.
  """

  alias Arbiter.Board.Autopilot
  alias Arbiter.Config.Paths
  alias Arbiter.Settings.Registry

  # A short budget and a caught exit: these calls are on the render path, and a
  # scheduler that cannot answer promptly must leave the operator with a page
  # and a flash, not a dead LiveView.
  @scheduler_call_timeout_ms 2_000

  @int_error "Enter a positive whole number (1 or more), or leave blank for the default."
  @adapters_error "Pick at least one agent type, or choose “all” or “none”."

  @doc "Message for a rejected positive-integer field."
  @spec int_error() :: String.t()
  def int_error, do: @int_error

  @doc """
  Parse a positive-integer form field: blank clears (`{:ok, nil}`), a whole
  number of 1 or more is `{:ok, n}`, anything else (`"0"`, `"-2"`, `"2.5"`,
  `"3 workers"`) is `:error`.
  """
  @spec parse_positive_int(term()) :: {:ok, pos_integer() | nil} | :error
  def parse_positive_int(raw) when is_binary(raw) do
    case raw |> String.trim() |> then(&{&1, Integer.parse(&1)}) do
      {"", _} -> {:ok, nil}
      {_, {n, ""}} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_positive_int(_), do: :error

  @doc """
  Validate and persist a positive-integer setting from its form text. Returns
  the stored override (`nil` once cleared) or the message to show beside the
  field; nothing is written on error.
  """
  @spec save_int(Registry.key(), term()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  def save_int(key, raw) do
    with {:ok, value} <- parse_positive_int(raw),
         {:ok, stored} <- Registry.put(key, value) do
      {:ok, stored}
    else
      :error -> {:error, @int_error}
      {:error, {:invalid, message}} -> {:error, message}
    end
  end

  @doc """
  Persist the watchdog's adapter choice. `"all"` clears the override (`nil` —
  probe every adapter), `"none"` stores `[]` (probe nothing), and `"only"`
  stores the ticked agent types — an empty tick list is refused, never quietly
  turned into "none".
  """
  @spec save_adapters(term(), term()) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  def save_adapters("all", _selected), do: put_adapters(nil)
  def save_adapters("none", _selected), do: put_adapters([])

  def save_adapters("only", selected) when is_list(selected) and selected != [],
    do: put_adapters(selected)

  def save_adapters(_mode, _selected), do: {:error, @adapters_error}

  defp put_adapters(value) do
    case Registry.put("credential_watchdog_adapters", value) do
      {:ok, stored} -> {:ok, stored}
      {:error, {:invalid, message}} -> {:error, message}
    end
  end

  # ---- the scheduler's autopilot --------------------------------------------

  @doc "Whether the board scheduler process is up on this install."
  @spec scheduler_running?() :: boolean()
  def scheduler_running? do
    Autopilot.running?(Autopilot)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  Whether the autopilot is paused. An unresponsive scheduler counts as paused —
  the reading that under-promises.
  """
  @spec scheduler_paused?() :: boolean()
  def scheduler_paused? do
    Autopilot.paused?(Autopilot, @scheduler_call_timeout_ms)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  @doc """
  The autopilot's `%{paused?, changed_at, changed_by}`, or `nil` when the
  scheduler is not running or does not answer in time.
  """
  @spec scheduler_status() :: map() | nil
  def scheduler_status do
    if scheduler_running?(), do: Autopilot.status(Autopilot, @scheduler_call_timeout_ms)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # bd-6i7yzq: who is flipping it — the dashboard operator's `Arbiter.Actor`
  # label, else the bare `"operator"` (no session in scope).
  @doc false
  @spec scheduler_actor() :: String.t()
  def scheduler_actor, do: Arbiter.Actor.resolve_label(nil) || "operator"

  @doc """
  Flip the autopilot, attributing the change to the dashboard. Pausing leaves
  in-flight work alone — it only stops the queue draining.
  """
  @spec toggle_scheduler() :: :ok | {:error, term()}
  def toggle_scheduler do
    if scheduler_paused?(),
      do: Autopilot.resume(Autopilot, {scheduler_actor(), "dashboard"}),
      else: Autopilot.pause(Autopilot, {scheduler_actor(), "dashboard"})
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Flash for a scheduler that is not up, or did not answer."
  @spec scheduler_error(:not_running | term()) :: String.t()
  def scheduler_error(:not_running), do: "The board scheduler isn't running on this install."
  def scheduler_error(_), do: "The board scheduler didn't answer — try that again."

  # ---- read-only diagnostics ------------------------------------------------

  @doc "The directories the install uses, as `[{key, label, path}]`."
  @spec paths() :: [{atom(), String.t(), String.t()}]
  def paths do
    [
      {:worktree_root, "Worktrees", Paths.worktree_root()},
      {:output_log_root, "Worker logs", Paths.output_log_root()},
      {:sessions_root, "Sessions", Paths.sessions_root()}
    ]
  end

  @doc """
  The address the HTTP listener is bound to: `%{ip, loopback}` (`ip` is `nil`
  when the endpoint config does not pin one). Shared with
  `GET /api/server/bind_address`.
  """
  @spec bind_address() :: %{ip: String.t() | nil, loopback: boolean()}
  def bind_address do
    ip =
      :arbiter_web
      |> Application.get_env(ArbiterWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:ip)

    %{ip: format_ip(ip), loopback: ArbiterWeb.Loopback.loopback?(ip)}
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
