defmodule ArbiterCli.Cmd.GrokToken do
  @moduledoc """
  arb grok-token

  Print a short-lived grok access token as `{"access_token", "expires_in"}` on
  stdout. This is the worker's `GROK_AUTH_PROVIDER_COMMAND` (bd-9p4lx9): grok
  runs it (through the wrapper `Arbiter.Grok.AuthProvider` installs) whenever it
  needs a credential, and again when the token nears expiry or the API answers
  401, with `GROK_AUTH_EXPIRED=1` set.

  The command asks the Arbiter server (`POST /api/grok/token`, with the worker's
  own `ARB_TOKEN`). The server is the only holder of grok's rotating refresh
  token and the only thing that refreshes it, so every worker's command is a
  thin client and none of them ever sees the refresh token.

  Exit status: 0 with the JSON on stdout; 1 with the reason on stderr (nothing
  on stdout) when the server has no token to give: the operator has to run
  `grok login` on the Arbiter host, or x.ai was unreachable.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      force? = System.get_env("GROK_AUTH_EXPIRED") == "1"

      case Client.post("/api/grok/token", %{force: force?}) do
        {:ok, %{"access_token" => token, "expires_in" => expires_in}}
        when is_binary(token) and token != "" ->
          IO.puts(Jason.encode!(%{access_token: token, expires_in: expires_in}))

        {:ok, _unexpected} ->
          Output.die("the server's grok token reply had no access_token")

        {:error, %Client.Error{} = error} ->
          Output.die(error)
      end
    end
  end
end
