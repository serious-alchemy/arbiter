defmodule ArbiterCli.Cmd.ReleaseDeploy.Status do
  @moduledoc """
  The deploy's own record of itself: `<data-home>/deploy-status.json`.

  `arb server deploy` restarts the server it is deploying, so nothing that lives
  in the server can narrate the deploy. The CLI writes this file instead —
  `start/2` when the deploy begins, `phase/1` as it moves, `finish/2` once with
  the outcome — and everything that wants to know reads it: `arb doctor`'s
  "last deploy" line, and the dashboard's update banner (which reads it after the
  server is back, `Arbiter.Release.DeployStatus`).

  Only the keys the deploy chooses to write are stored, and any `GITHUB_TOKEN`
  value in a message is redacted, so the file is safe to show.

  States: `running`, `succeeded`, `rolled_back`, `refused` (health check failed
  and rollback was declined), `failed` (stopped before the swap, e.g. a failed
  download or backup). The outcome is recorded once: a later `finish/2` in the
  same process (a halt hook firing after the real outcome) is ignored.
  """

  alias ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles

  @file_name "deploy-status.json"
  # A "running" record this old with no live process is an interrupted deploy.
  @stale_after_s 15 * 60

  # `:bd2_deploy_status_path` is the test seam: `ArbiterCli.CliCase` points it at
  # nothing so no test reads the host's real record; tests that exercise the file
  # itself delete it and go through `ARB_DATA_HOME`.
  @spec path() :: String.t()
  def path do
    case Process.get(:bd2_deploy_status_path) do
      path when is_binary(path) -> path
      _ -> Path.join(ReleaseFiles.data_home(), @file_name)
    end
  end

  @doc "The last recorded deploy, or nil when there is none (or the file is unreadable)."
  @spec read() :: map() | nil
  def read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = status} <- Jason.decode(body) do
      status
    else
      _ -> nil
    end
  end

  @spec start(String.t(), map()) :: :ok
  def start(tag, extra) do
    Process.put(:arb_deploy_status_finished, false)
    now = now()

    write(%{
      "state" => "running",
      "tag" => tag,
      "pid" => System.pid(),
      "started_at" => now,
      "updated_at" => now,
      "phase" => "starting"
    })

    merge(extra)
  end

  @doc """
  Record a deploy that stopped before `start/2` — an active-worker refusal, a
  failed release lookup. Nothing ran, so this is written only when the stop
  happens (never as a `running` placeholder): a no-op deploy that finds the
  release already current leaves the prior record alone.
  """
  @spec fail_early(String.t(), String.t() | nil) :: :ok
  def fail_early(tag, message) do
    Process.put(:arb_deploy_status_finished, true)
    now = now()

    write(%{
      "state" => "failed",
      "tag" => tag,
      "phase" => "preflight",
      "started_at" => now,
      "updated_at" => now,
      "finished_at" => now,
      "message" => message || "the deploy stopped before it began"
    })
  end

  @spec phase(String.t()) :: :ok
  def phase(name), do: merge(%{"phase" => name})

  @doc "Record the outcome, once."
  @spec finish(String.t(), map()) :: :ok
  def finish(state, extra) do
    if Process.get(:arb_deploy_status_finished, false) do
      :ok
    else
      Process.put(:arb_deploy_status_finished, true)
      merge(Map.merge(%{"state" => state, "finished_at" => now()}, stringify(extra)))
    end
  end

  @doc "One line for `arb doctor` and the like."
  @spec describe(map()) :: String.t()
  def describe(%{"state" => "running"} = s) do
    if interrupted?(s) do
      "deploy of #{s["tag"]} was interrupted (started #{s["started_at"]}; no live process) — " <>
        "check `arb doctor` and re-run `arb server deploy`"
    else
      "deploy of #{s["tag"]} in progress (#{s["phase"] || "starting"})"
    end
  end

  def describe(%{"state" => state} = s) do
    outcome =
      case state do
        "succeeded" -> "succeeded"
        "rolled_back" -> "rolled back to #{s["rolled_back_to"]}"
        "refused" -> "failed, rollback refused (still on #{s["tag"]})"
        "failed" -> "failed before the swap" <> message_suffix(s)
        other -> other
      end

    [
      "last deploy #{s["tag"]} #{outcome}",
      s["finished_at"] && "at #{s["finished_at"]}",
      s["restored_database"] == true && "(database restored)",
      backup_clause(s)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  def describe(_), do: "last deploy: unreadable record"

  @doc "A `running` record whose process is gone or that has not moved for a long while."
  @spec interrupted?(map()) :: boolean()
  def interrupted?(%{"state" => "running"} = s) do
    not alive?(s["pid"]) or stale?(s["updated_at"])
  end

  def interrupted?(_), do: false

  # ---- internals -------------------------------------------------------------

  defp backup_clause(%{"backup_path" => p}) when is_binary(p), do: "backup #{p}"
  defp backup_clause(_), do: "(no database backup taken)"

  defp message_suffix(%{"message" => m}) when is_binary(m) and m != "", do: ": #{m}"
  defp message_suffix(_), do: ""

  defp merge(extra) do
    current = read() || %{}

    current
    |> Map.merge(stringify(extra))
    |> Map.put("updated_at", now())
    |> write()
  end

  defp write(map) do
    file = path()
    File.mkdir_p!(Path.dirname(file))
    tmp = file <> ".tmp"
    File.write!(tmp, map |> scrub() |> Jason.encode!(pretty: true))
    File.rename!(tmp, file)
    :ok
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Redact the token by value, wherever it ended up in a string field.
  defp scrub(map) do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and byte_size(token) >= 8 ->
        Map.new(map, fn
          {k, v} when is_binary(v) -> {k, String.replace(v, token, "[redacted]")}
          kv -> kv
        end)

      _ ->
        map
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp alive?(pid) when is_binary(pid) and pid != "", do: File.exists?("/proc/" <> pid)
  defp alive?(_), do: false

  defp stale?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at) > @stale_after_s
      _ -> true
    end
  end

  defp stale?(_), do: true
end
