defmodule Arbiter.Server.Status do
  @moduledoc """
  The server's own identity and schema state, read by `GET /api/version`,
  `GET /api/server/migrations` and the `server_status` MCP tool, so the three
  cannot disagree. Every value is a version stamp, a timestamp, a count or a
  `owner/repo` — never a host path.
  """

  @doc "Version, git sha, build and boot timestamps, release repo, and the update-check block."
  @spec version() :: map()
  def version do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    %{
      version: Arbiter.Version.app_version(),
      sha: Arbiter.Version.git_sha(),
      built_at: Arbiter.Version.built_at(),
      booted_at: booted_at,
      release_repo: Arbiter.Version.release_repo(),
      update: update()
    }
  end

  @doc "`Arbiter.Release.UpdateCheck`'s last result, JSON-shaped."
  @spec update() :: map()
  def update do
    u = Arbiter.Release.UpdateCheck.state()

    %{
      enabled: u.enabled,
      latest: u.latest,
      release_url: u.release_url,
      checked_at: u.checked_at && DateTime.to_iso8601(u.checked_at),
      update_available: u.update_available?,
      migrations_pending: u.migrations_pending,
      error: u.error
    }
  end

  @doc "Pending-migration status: `ok` (none), `warning` (some) or `unknown` (unreadable)."
  @spec migrations() :: map()
  def migrations do
    case Arbiter.Migrations.count_pending() do
      {:ok, 0} -> %{status: "ok", pending_count: 0}
      {:ok, count} -> %{status: "warning", pending_count: count}
      {:error, reason} -> %{status: "unknown", pending_count: nil, error: Atom.to_string(reason)}
    end
  end

  @doc """
  What the `server_status` MCP tool returns: the version read with the
  migration status folded in under `migrations`, and the update block at the
  top level.
  """
  @spec snapshot() :: map()
  def snapshot, do: Map.put(version(), :migrations, migrations())
end
