defmodule ArbiterCli.ArgParser do
  @moduledoc """
  Shared `OptionParser` wrapper for `arb` subcommands.

  Most subcommands repeat the same three steps: parse flags out of argv,
  split off positionals, and decide `:text` vs `:json` mode from a `--json`
  switch. `parse/2` does all three in one call so subcommand modules don't
  hand-roll it — and enforces the CLI parsing contract (bd-cqw11s): unknown
  flags and unparseable typed values are errors, never silently dropped.
  """

  alias ArbiterCli.Output

  @doc """
  Parses `argv` against `opts[:switches]` (`opts[:strict]` is accepted as a
  synonym), returning `{parsed, rest, mode}`.

  The parse is **strict**: an unknown flag, or a flag whose value does not
  parse as its declared type (`--priority abc` against `priority: :integer`),
  dies via `ArbiterCli.Output.die/1` with exit 1 — the message names the flag
  and the command (`unknown option --x for arb ticket list`). Nothing is
  silently dropped, and the bad flag cannot swallow the next token because the
  run ends there. `opts[:command]` is the label printed in the message
  (`"arb ticket list"`); `opts[:hint]` is an optional `(flag -> String.t())`
  producing a detail line passed to `Output.die/2` for an unknown flag.

  `--json` and `--help`/`-h` are always accepted so every caller gets `:json`
  mode detection without declaring them. Pass `opts[:aliases]` to forward short
  flags to `OptionParser`.

  The one explicit opt-out is `passthrough: true` for verbs whose trailing
  words are free text that may legitimately start with a dash
  (`arb message <id> <text…>`): unknown flags are then kept in `parsed`/`rest`
  the way `OptionParser`'s lenient mode leaves them, and typed-flag failures
  are dropped. A verb that opts out must say why at the call site.
  """
  @spec parse([String.t()], keyword()) :: {keyword(), [String.t()], :text | :json}
  def parse(argv, opts) do
    declared = declared_switches(opts)
    aliases = aliases(opts)

    if Keyword.get(opts, :passthrough, false) do
      {parsed, rest, _invalid} =
        OptionParser.parse(argv, [switches: declared] ++ alias_opts(aliases))

      {parsed, rest, mode(parsed)}
    else
      {parsed, rest, invalid} =
        OptionParser.parse(argv, [strict: declared] ++ alias_opts(aliases))

      reject_invalid!(invalid, declared, aliases, opts)
      {parsed, rest, mode(parsed)}
    end
  end

  @doc """
  Like `parse/2`, with `command_label` (e.g. `"arb server deploy"`) naming the
  subcommand in the error message and `opts[:strict]` the switch list.
  """
  @spec parse_strict!([String.t()], String.t(), keyword()) ::
          {keyword(), [String.t()], :text | :json}
  def parse_strict!(argv, command_label, opts) do
    parse(argv, Keyword.put(opts, :command, command_label))
  end

  @doc """
  Coerces a `--difficulty` value to an integer `0..5`. Accepts `"3"` and the
  `D3` / `d3` spelling the help text advertises; anything else dies.
  `nil` (flag absent) passes through as `nil`.
  """
  @spec difficulty!(String.t() | nil) :: 0..5 | nil
  def difficulty!(nil), do: nil

  def difficulty!(value) when is_binary(value) do
    digits = String.replace(value, ~r/^[Dd]/, "")

    case Integer.parse(digits) do
      {n, ""} when n in 0..5 -> n
      _ -> ArbiterCli.Output.die("invalid --difficulty #{inspect(value)} (must be 0..5 / D0..D5)")
    end
  end

  @doc """
  Replaces a parsed `:difficulty` string in `opts` with its `difficulty!/1`
  integer, so a caller that declares `difficulty: :string` gets `D3` / `3`
  coerced in one step.
  """
  @spec coerce_difficulty(keyword()) :: keyword()
  def coerce_difficulty(opts) do
    case Keyword.fetch(opts, :difficulty) do
      {:ok, value} -> Keyword.put(opts, :difficulty, difficulty!(value))
      :error -> opts
    end
  end

  defp mode(parsed), do: if(parsed[:json], do: :json, else: :text)

  defp declared_switches(opts) do
    base = Keyword.get(opts, :strict) || Keyword.get(opts, :switches, [])

    Enum.reduce([json: :boolean, help: :boolean], base, fn {key, _} = pair, acc ->
      if Keyword.has_key?(acc, key), do: acc, else: acc ++ [pair]
    end)
  end

  defp aliases(opts) do
    base = Keyword.get(opts, :aliases, [])
    if Keyword.has_key?(base, :h), do: base, else: base ++ [h: :help]
  end

  defp alias_opts([]), do: []
  defp alias_opts(aliases), do: [aliases: aliases]

  defp reject_invalid!([], _declared, _aliases, _opts), do: :ok

  defp reject_invalid!([{flag, value} | _], declared, aliases, opts) do
    command = Keyword.get(opts, :command, "arb")

    if declared?(flag, declared, aliases) do
      Output.die(bad_value_message(flag, value, flag_type(flag, declared, aliases), command))
    else
      message = "unknown option #{flag} for #{command}"

      case Keyword.get(opts, :hint) do
        nil -> Output.die(message)
        hint -> Output.die(message, hint.(flag))
      end
    end
  end

  defp bad_value_message(flag, nil, _type, command),
    do: "option #{flag} for #{command} requires a value"

  defp bad_value_message(flag, value, type, command) do
    "invalid value #{inspect(value)} for #{flag} on #{command} (expected #{type_name(type)})"
  end

  defp type_name(:integer), do: "an integer"
  defp type_name(:float), do: "a number"
  defp type_name(_), do: "a valid value"

  defp declared?(flag, declared, aliases), do: flag_key(flag, declared, aliases) != nil

  defp flag_type(flag, declared, aliases) do
    case flag_key(flag, declared, aliases) do
      nil -> nil
      key -> declared |> Keyword.fetch!(key) |> List.wrap() |> List.first()
    end
  end

  # The declared switch atom a typed flag string (`--auto-close`, `-r`)
  # refers to, or nil when it is not declared.
  defp flag_key("--" <> name, declared, _aliases), do: find_key(name, declared)

  defp flag_key("-" <> name, declared, aliases) do
    case Enum.find(aliases, fn {alias_name, _} -> Atom.to_string(alias_name) == name end) do
      {_, key} -> if Keyword.has_key?(declared, key), do: key
      nil -> nil
    end
  end

  defp flag_key(_other, _declared, _aliases), do: nil

  defp find_key(name, declared) do
    normalized = String.replace(name, "-", "_")
    Enum.find_value(Keyword.keys(declared), &if(Atom.to_string(&1) == normalized, do: &1))
  end

  @doc """
  Runs `fun.()` unless `--help`/`-h` is present in `argv`, in which case
  `usage_text` is printed instead. Mirrors the `if Output.help?(argv) ...`
  guard every subcommand's `run/1` starts with.
  """
  @spec unless_help([String.t()], String.t(), (-> any())) :: any()
  def unless_help(argv, usage_text, fun) do
    if "--help" in argv or "-h" in argv do
      IO.puts(usage_text)
    else
      fun.()
    end
  end
end
