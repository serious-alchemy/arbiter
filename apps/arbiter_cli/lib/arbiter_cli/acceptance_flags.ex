defmodule ArbiterCli.AcceptanceFlags do
  @moduledoc """
  `--acceptance TEXT` / `--acceptance-file PATH` for `arb ticket create` and
  `arb ticket update` (P-08, D-T-8).

  Acceptance criteria are multi-line markdown, which is awkward to quote on a
  command line; `--acceptance-file` reads them from a file (`-` reads stdin).
  The two flags are alternatives — passing both is refused rather than letting
  one silently win. `""` is passed through as-is: on `update` it clears the
  field.
  """

  alias ArbiterCli.Output

  @switches [acceptance: :string, acceptance_file: :string]

  @doc "The switch declarations to splice into a verb's switch list."
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc """
  The acceptance text for `opts` (`nil` when neither flag was given). Dies with
  exit 1 when both were given or the file cannot be read.
  """
  @spec resolve!(keyword()) :: String.t() | nil
  def resolve!(opts) do
    case {opts[:acceptance], opts[:acceptance_file]} do
      {nil, nil} ->
        nil

      {text, nil} ->
        text

      {nil, path} ->
        read!(path)

      {_text, _path} ->
        Output.die("--acceptance and --acceptance-file are alternatives; pass one")
    end
  end

  defp read!("-") do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> data
      _ -> Output.die("--acceptance-file -: nothing on stdin")
    end
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, text} ->
        text

      {:error, reason} ->
        Output.die("cannot read --acceptance-file #{path}: #{:file.format_error(reason)}")
    end
  end
end
