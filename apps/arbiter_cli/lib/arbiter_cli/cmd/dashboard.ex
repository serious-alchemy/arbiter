defmodule ArbiterCli.Cmd.Dashboard do
  @moduledoc """
  `arb dashboard login [--json]` — sign the browser in to the dashboard.

  The dashboard has no address bypass (a request proxied by `tailscale serve`
  arrives from 127.0.0.1), so every browser needs a login. This mints a
  one-time link over the authenticated API and prints it; open it in the
  browser and confirm. The link is valid for a couple of minutes and works
  once. The server's `ArbiterWeb.DashboardAuth` implementation decides what a
  login is — this command is the default implementation's escape hatch for
  the local operator.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

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
    case Client.post("/api/dashboard/login_tokens", %{}) do
      {:ok, %{"path" => path} = body} ->
        url = Client.base_url() <> path

        case mode do
          :json -> IO.puts(Jason.encode!(Map.put(body, "url", url)))
          :text -> IO.puts(url)
        end

      {:error, %Client.Error{} = err} ->
        Output.die(err)
    end
  end
end
