defmodule Arbiter.Accounts.LoginRecipe do
  @moduledoc """
  Data describing how to drive one provider CLI's **own** login flow and how
  to read its output (login relay, bd-dqvv90; recorded by spike bd-29ycw1).

  Arbiter never speaks OAuth itself: it runs `command` + `args` with
  `config_dir_env` pointed at an isolated dir, relays the CLI's I/O, and
  scrapes the auth URL / device code / outcome using the patterns below.

  Patterns are applied to screen text after `strip_ansi/1` (which also
  unwraps OSC-8 hyperlinks). `nil` means "this CLI has no such screen".

  `credential_path` is a reference only (relative to the config dir) — the
  credential is never read or copied by Arbiter.
  """

  @enforce_keys [:provider, :command, :args, :config_dir_env]
  defstruct [
    :provider,
    :command,
    :args,
    :config_dir_env,
    :flow,
    :status_command,
    :status_success,
    :url_pattern,
    :code_prompt_pattern,
    :device_code_pattern,
    :success_pattern,
    :failure_pattern,
    :credential_path,
    :status_fallback_file,
    enabled?: true
  ]

  @type flow :: :paste_code | :device_code

  @type status_success ::
          {:exit_zero}
          | {:json, [String.t()], term()}

  @type t :: %__MODULE__{
          provider: atom(),
          command: String.t(),
          args: [String.t()],
          config_dir_env: String.t(),
          flow: flow(),
          status_command: [String.t()] | nil,
          status_success: status_success() | nil,
          url_pattern: Regex.t() | nil,
          code_prompt_pattern: Regex.t() | nil,
          device_code_pattern: Regex.t() | nil,
          success_pattern: Regex.t() | nil,
          failure_pattern: Regex.t() | nil,
          credential_path: String.t() | nil,
          status_fallback_file: String.t() | nil,
          enabled?: boolean()
        }

  # OSC sequences (incl. OSC-8 hyperlinks), terminated by BEL or ESC \.
  @osc8 ~r/\e\]8;[^;\e\a]*;([^\e\a]*)(?:\e\\|\a)(.*?)\e\]8;;(?:\e\\|\a)/s
  @osc ~r/\e\][^\e\a]*(?:\e\\|\a)/
  @csi ~r/\e\[[0-9;?]*[ -\/]*[@-~]/

  @doc """
  Strip terminal escapes from `text`. An OSC-8 hyperlink keeps its visible
  text; when that text is not itself the URL (e.g. a truncated label) the
  link target is used instead, so the full URL always survives.
  """
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@osc8, &1, fn _, target, label -> link_text(target, label) end))
    |> then(&Regex.replace(@osc, &1, ""))
    |> then(&Regex.replace(@csi, &1, ""))
    |> String.replace("\r", "")
  end

  defp link_text("", label), do: label

  defp link_text(target, label) do
    if String.starts_with?(String.trim(label), target), do: label, else: target
  end

  @doc "The auth URL printed by the CLI, or `nil`."
  @spec extract_url(t(), String.t()) :: String.t() | nil
  def extract_url(%__MODULE__{url_pattern: nil}, _text), do: nil

  def extract_url(%__MODULE__{url_pattern: re}, text), do: capture(re, strip_ansi(text))

  @doc "The one-time device code (device-code flows only), or `nil`."
  @spec extract_device_code(t(), String.t()) :: String.t() | nil
  def extract_device_code(%__MODULE__{device_code_pattern: nil}, _text), do: nil

  def extract_device_code(%__MODULE__{device_code_pattern: re}, text),
    do: capture(re, strip_ansi(text))

  @doc "True when the CLI is waiting for the operator to paste a code."
  @spec awaiting_code?(t(), String.t()) :: boolean()
  def awaiting_code?(%__MODULE__{code_prompt_pattern: nil}, _text), do: false

  def awaiting_code?(%__MODULE__{code_prompt_pattern: re}, text),
    do: Regex.match?(re, strip_ansi(text))

  @doc "True when the screen text shows the CLI's success line."
  @spec success?(t(), String.t()) :: boolean()
  def success?(%__MODULE__{success_pattern: nil}, _text), do: false
  def success?(%__MODULE__{success_pattern: re}, text), do: Regex.match?(re, strip_ansi(text))

  @doc "True when the screen text shows a failure line."
  @spec failure?(t(), String.t()) :: boolean()
  def failure?(%__MODULE__{failure_pattern: nil}, _text), do: false
  def failure?(%__MODULE__{failure_pattern: re}, text), do: Regex.match?(re, strip_ansi(text))

  @doc """
  Decide login success from the status command's result (`exit` code and
  `output`), per the recipe's `status_success`. `false` when the recipe has
  no status command.
  """
  @spec status_ok?(t(), non_neg_integer(), String.t()) :: boolean()
  def status_ok?(%__MODULE__{status_success: nil}, _exit, _output), do: false
  def status_ok?(%__MODULE__{status_success: {:exit_zero}}, exit, _output), do: exit == 0

  def status_ok?(%__MODULE__{status_success: {:json, path, expected}}, 0, output) do
    case Jason.decode(output) do
      {:ok, decoded} -> get_in_path(decoded, path) == expected
      _ -> false
    end
  end

  def status_ok?(%__MODULE__{status_success: {:json, _, _}}, _exit, _output), do: false

  defp get_in_path(value, []), do: value
  defp get_in_path(%{} = map, [key | rest]), do: get_in_path(Map.get(map, key), rest)
  defp get_in_path(_, _), do: nil

  defp capture(re, text) do
    case Regex.run(re, text, capture: :all_but_first) do
      [value | _] -> value
      _ -> nil
    end
  end
end
