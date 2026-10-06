defmodule ArbiterCli.SecretInput do
  @moduledoc """
  Where a secret value comes from when a verb takes one (P-28,
  `docs/design/tier-proof-boundaries.md`).

  A secret on argv is visible to every process on the host (`ps`, `/proc`) and
  lands in shell history, so each secret-taking verb offers a `--file PATH` or
  `-` (stdin) form, and the argv form still works but warns on stderr. The
  warning never prints the value.
  """

  alias ArbiterCli.Output

  @doc "Read a secret from `path`, trimmed; dies naming `flag` when unreadable."
  @spec from_file!(String.t(), String.t()) :: String.t()
  def from_file!(path, flag) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      {:error, reason} -> Output.die("cannot read #{flag}: #{:file.format_error(reason)}")
    end
  end

  @doc "Read a secret from stdin to EOF, trimmed."
  @spec from_stdin!() :: String.t()
  def from_stdin! do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> String.trim(data)
      _ -> ""
    end
  end

  @doc "Warn (stderr) that a secret was passed on the command line; `alt` names the safer forms."
  @spec warn_argv(String.t()) :: :ok
  def warn_argv(alt) do
    IO.puts(
      :stderr,
      "warning: a secret on the command line is visible to other processes and shell " <>
        "history; prefer #{alt}"
    )
  end
end
