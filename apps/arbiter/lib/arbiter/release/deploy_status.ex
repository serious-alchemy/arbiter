defmodule Arbiter.Release.DeployStatus do
  @moduledoc """
  Read side of `<data-home>/deploy-status.json`, the record `arb server deploy`
  keeps of itself (`ArbiterCli.Cmd.ReleaseDeploy.Status` writes it).

  A deploy restarts the server it is deploying, so the CLI — not the server — is
  the only party that can narrate it; the server reads the file after it is back
  to show the dashboard's progress and outcome, and to refuse a second deploy
  while one is running. Read-only here: the server never writes it.
  """

  # A "running" record this old with no recent update is an interrupted deploy.
  @stale_after_s 15 * 60

  @doc "Where the CLI writes the record."
  @spec path() :: String.t()
  def path, do: Path.join(Arbiter.Nodes.Agent.data_home(), "deploy-status.json")

  @doc "The last recorded deploy, or nil when there is none or it is unreadable."
  @spec read() :: map() | nil
  def read do
    with {:ok, body} <- File.read(path()),
         {:ok, %{} = status} <- Jason.decode(body) do
      status
    else
      _ -> nil
    end
  end

  @doc """
  Whether `status` is a deploy that is really in progress: recorded as running,
  its process still alive, and updated recently. A `running` record whose process
  died (killed, host reboot) is not — it must not block the next deploy forever.
  """
  @spec running?(map() | nil) :: boolean()
  def running?(%{"state" => "running"} = status),
    do: alive?(status["pid"]) and fresh?(status["updated_at"])

  def running?(_), do: false

  @doc "A `running` record that is not actually running."
  @spec interrupted?(map() | nil) :: boolean()
  def interrupted?(%{"state" => "running"} = status), do: not running?(status)
  def interrupted?(_), do: false

  defp alive?(pid) when is_binary(pid) and pid != "", do: File.exists?("/proc/" <> pid)
  defp alive?(_), do: false

  defp fresh?(nil), do: true

  defp fresh?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at) <= @stale_after_s
      _ -> false
    end
  end

  defp fresh?(_), do: false
end
