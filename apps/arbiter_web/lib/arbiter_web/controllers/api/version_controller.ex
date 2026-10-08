defmodule ArbiterWeb.Api.VersionController do
  @moduledoc """
  GET /api/version — server version stamp.

  Returns the app version, git SHA, build timestamp, and boot timestamp so
  `arb version` can compare them against the installed CLI escript and flag
  drift. `release_repo` is the GitHub `owner/repo` this install takes releases from
  (`ARB_RELEASE_REPO`, else the repo the build was stamped with), so `arb server deploy`
  can find its source without any exported environment. The `update` block is `Arbiter.Release.UpdateCheck`'s last result
  (latest published release, whether it is newer, and the last check error).
  """

  use ArbiterWeb, :controller

  def show(conn, _params), do: json(conn, Arbiter.Server.Status.version())

  @doc false
  def update_payload, do: Arbiter.Server.Status.update()
end
