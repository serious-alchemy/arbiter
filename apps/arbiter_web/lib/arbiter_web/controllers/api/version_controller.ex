defmodule ArbiterWeb.Api.VersionController do
  @moduledoc """
  GET /api/version — server version stamp.

  Returns the app version, git SHA, build timestamp, and boot timestamp so
  `arb version` can compare them against the installed CLI escript and flag
  drift. The `update` block is `Arbiter.Release.UpdateCheck`'s last result
  (latest published release, whether it is newer, and the last check error).
  """

  use ArbiterWeb, :controller

  def show(conn, _params) do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    booted_at =
      DateTime.utc_now()
      |> DateTime.add(-div(uptime_ms, 1000), :second)
      |> DateTime.to_iso8601()

    json(conn, %{
      version: Arbiter.Version.app_version(),
      sha: Arbiter.Version.git_sha(),
      built_at: Arbiter.Version.built_at(),
      booted_at: booted_at,
      update: update_payload()
    })
  end

  @doc false
  def update_payload do
    u = Arbiter.Release.UpdateCheck.state()

    %{
      enabled: u.enabled,
      latest: u.latest,
      release_url: u.release_url,
      checked_at: u.checked_at && DateTime.to_iso8601(u.checked_at),
      update_available: u.update_available?,
      error: u.error
    }
  end
end
