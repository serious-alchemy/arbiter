defmodule ArbiterWeb.LoginTranscriptController do
  @moduledoc """
  The redacted final screen of a finished dashboard login (login relay 6/6,
  bd-bh50vs), linked from the Providers page's Login history.

  `Arbiter.Accounts.LoginTranscript` already stripped URL query strings and
  blanked the device/auth codes and operator keystrokes before the row was
  written, but it is still a login screen: it is served under the same rule as
  a session transcript (§10.4) — a loopback peer, or 403. `text/plain`, so a
  stored byte can never run as markup.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts.Logins

  plug :require_loopback

  def show(conn, %{"id" => id}) do
    case Logins.get_record(id) do
      {:ok, record} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, record.transcript || "")

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "no such login")
    end
  end

  defp require_loopback(conn, _opts) do
    if ArbiterWeb.Loopback.loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "login transcripts are served to a loopback peer only")
      |> halt()
    end
  end
end
