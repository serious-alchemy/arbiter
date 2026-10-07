defmodule ArbiterCli.Cmd.Dashboard do
  @moduledoc """
  `arb dashboard login [--json]` — sign the browser in to the dashboard.

  The dashboard has no address bypass (a request proxied by `tailscale serve`
  arrives from 127.0.0.1), so every browser needs a login. This mints a
  one-time link and prints it; open it in the
  browser and confirm. The link is valid for a couple of minutes and works
  once. The server's `ArbiterWeb.DashboardAuth` implementation decides what a
  login is — this command is the default implementation's escape hatch for
  the local operator.

  Minting a dashboard login is an operator act (P-28,
  `docs/design/tier-proof-boundaries.md`): the CLI first mints a short-lived
  coordinator token over the operator socket (`ArbiterCli.OperatorSocket`,
  peer-credential checked, refused for any process Arbiter spawned) and sends
  that — never `ARB_TOKEN`, which a coordinator session also holds — to
  `POST /api/dashboard/login_tokens`. Run it from your own shell on the
  server host.
  """

  # Long enough for the one request that follows; the login link itself has
  # its own (separate) lifetime.
  @proof_ttl 300

  alias ArbiterCli.{ArgParser, Client, OperatorSocket, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} = ArgParser.parse(argv, command: "arb dashboard", switches: [])

      case rest do
        ["login" | _] -> login(mode)
        _ -> Output.die("usage: arb dashboard login [--json]")
      end
    end
  end

  defp login(mode) do
    with {:ok, %{"token" => proof}} <- OperatorSocket.mint(%{"ttl" => @proof_ttl}),
         {:ok, %{"path" => path} = body} <-
           Client.post_with_token("/api/dashboard/login_tokens", %{}, proof) do
      url = Client.base_url() <> path

      case mode do
        :json -> IO.puts(Jason.encode!(Map.put(body, "url", url)))
        :text -> IO.puts(url)
      end
    else
      {:error, %Client.Error{} = err} ->
        Output.die(err)
    end
  end
end
