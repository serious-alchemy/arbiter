defmodule Arbiter.Agents.Grok.Credential do
  @moduledoc """
  The seam through which a grok spawn gets its credential (bd-9ydvov).

  The design (bd-73uvlo / bd-7nbwix) is a single credential broker: one
  refresher owns the operator's rotating OIDC refresh token and hands each
  worker a short-lived access token through `GROK_AUTH_PROVIDER_COMMAND` (or the
  operator supplies `XAI_API_KEY`). Copying `auth.json` into every worker would
  race the rotation and make grok delete the loser's login. That broker is a
  separate task; until it lands this module is the stub, and the answer is
  `[]`, so a spawn is "not signed in" rather than sharing the operator's login.

  Configure it with `config :arbiter, :grok_credential_env`, either a list of
  `{name, value}` pairs or a function of the spawn opts returning one. The
  values are secrets: nothing here logs them, and the worker's redaction path
  scrubs them from the transcript like any other secret env.
  """

  @doc "The credential env pairs for a spawn with `opts`."
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    case Application.get_env(:arbiter, :grok_credential_env) do
      fun when is_function(fun, 1) -> pairs(fun.(opts))
      list when is_list(list) -> pairs(list)
      _ -> []
    end
  end

  defp pairs(list) when is_list(list),
    do: Enum.filter(list, &match?({k, v} when is_binary(k) and is_binary(v), &1))

  defp pairs(_), do: []
end
