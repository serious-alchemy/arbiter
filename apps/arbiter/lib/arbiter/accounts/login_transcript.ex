defmodule Arbiter.Accounts.LoginTranscript do
  @moduledoc """
  Redaction for a dashboard login's pane transcript (login relay 5/6,
  bd-2prmjm, epic bd-dqvv90).

  The login pane carries things that must never reach a log line, the DB or a
  shared PubSub topic: the auth URL (its query string holds `state` and
  `code_challenge`), the device/user code, and whatever the operator pasted
  back (the terminal echoes it). `redact/3` is the only way a pane's text
  becomes a stored transcript:

    * terminal escapes are stripped;
    * every `http(s)://…` URL keeps its scheme, host and path but loses its
      query string and fragment;
    * the recipe's device-code capture and every value in `secrets` (the
      extracted codes and every relayed paste) are blanked, wherever they
      appear — including in the echoed keystrokes.
  """

  alias Arbiter.Accounts.LoginRecipe

  @redacted "[REDACTED]"
  @url ~r|(https?://[^\s?#]*)[?#]\S*|

  @doc "The placeholder written over a blanked value."
  @spec placeholder() :: String.t()
  def placeholder, do: @redacted

  @spec redact(String.t(), LoginRecipe.t() | nil, [String.t() | nil]) :: String.t()
  def redact(text, recipe, secrets) when is_binary(text) do
    text
    |> LoginRecipe.strip_ansi()
    |> then(&Regex.replace(@url, &1, "\\1?#{@redacted}"))
    |> blank_device_code(recipe)
    |> blank_secrets(secrets)
  end

  defp blank_device_code(text, %LoginRecipe{device_code_pattern: %Regex{} = re}) do
    Regex.replace(re, text, fn full, code -> String.replace(full, code, @redacted) end)
  end

  defp blank_device_code(text, _recipe), do: text

  defp blank_secrets(text, secrets) do
    secrets
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    # Longest first: a short secret that is a substring of a longer one must
    # not leave the tail of the longer one behind.
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.reduce(text, &String.replace(&2, &1, @redacted))
  end
end
