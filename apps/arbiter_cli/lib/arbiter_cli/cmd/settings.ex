defmodule ArbiterCli.Cmd.Settings do
  @moduledoc """
  `arb settings` — read and change the install-wide runtime settings (the
  `installation_config_*` MCP tools' keys), backed by
  `GET|PATCH /api/installation/config`.

      arb settings get   [key] [--json]
      arb settings set   <key> <value>
      arb settings unset <key>
      arb settings schema [--json]

  Secrets (`nodes.registry_password`) are write-only and always strings; prefer
  `arb settings set nodes.registry_password -` (stdin) or `--file <path>` to argv.

  `get` shows, per key, the value in force, whether it comes from an
  `override` or the `default`, and what the default is. `unset` (and
  `set <key> null`) clears the override.

  ## Values

  `set` parses `<value>` as JSON when it can: `5`, `["claude","codex"]`,
  `[]`, `null`. Anything else is sent as a string and rejected by the server
  with the allowed values. For the list keys `null` (no override — all
  adapters / auto-detect), a list, and `[]` (none) are three distinct values:

      arb settings set credential_watchdog_adapters '["claude"]'
      arb settings set credential_watchdog_adapters '[]'     # probe nothing
      arb settings unset credential_watchdog_adapters        # back to all

  Validation is the server's (`Arbiter.Settings.Registry`), identical to the
  MCP tool; an invalid value is rejected and nothing changes. Coordinator
  tokens only (the same tier as the MCP `installation_config_set`).

  ## Autopilot

  The board autopilot is not an installation setting key. `get` lists its
  state read-only for completeness; pause and resume stay under
  `arb scheduler pause|resume|status|wait` (`/api/scheduler/*`).
  """

  alias ArbiterCli.{ArgParser, Client, Output, SecretInput}
  alias ArbiterCli.Cmd.Config.Value

  @path "/api/installation/config"

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv, command: "arb settings", switches: [file: :string])

      case rest do
        ["get" | args] -> get(args, mode)
        ["set" | args] -> set(args, opts, mode)
        ["unset" | args] -> unset(args, mode)
        ["schema" | _] -> schema(mode)
        [] -> Output.die("settings requires a subcommand: get, set, unset, or schema")
        [unknown | _] -> Output.die("unknown settings subcommand: #{unknown}")
      end
    end
  end

  defp get([], mode) do
    body = fetch!(%{})

    if mode == :json do
      Output.emit_json(body)
    else
      Enum.each(body["data"], &print_item/1)
      print_autopilot()
    end
  end

  defp get([key], mode) do
    body = fetch!(%{"key" => key})
    if mode == :json, do: Output.emit_json(body), else: print_item(body["data"])
  end

  defp get(_, _), do: Output.die("settings get takes at most one argument: the key")

  # A secret key (`Registry`'s "secret" type) is always a string — "12345" must
  # not become an integer — and has a stdin / file form so it need not ride argv
  # (visible to `ps` and shell history).
  @secret_keys ["nodes.registry_password"]

  defp set([key | rest], opts, mode) when key in @secret_keys do
    value =
      case {rest, opts[:file]} do
        {[], file} when is_binary(file) ->
          SecretInput.from_file!(file, "--file")

        {["-"], nil} ->
          SecretInput.from_stdin!()

        {[raw], nil} ->
          SecretInput.warn_argv("`arb settings set #{key} -` (stdin) or `--file <path>`")
          raw

        _ ->
          Output.die("settings set #{key} takes one value: <value>, - (stdin), or --file <path>")
      end

    patch(key, value, mode)
  end

  defp set([key, raw], _opts, mode), do: patch(key, parse(raw), mode)

  defp set([key | rest], _opts, mode) when rest != [],
    do: patch(key, parse(Enum.join(rest, " ")), mode)

  defp set([_], _opts, _mode),
    do: Output.die("settings set requires a value: arb settings set <key> <value>")

  defp set([], _opts, _mode), do: Output.die("settings set requires <key> <value>")

  defp unset([key], mode), do: patch(key, nil, mode)
  defp unset(_, _), do: Output.die("settings unset takes exactly one argument: the key")

  defp patch(key, value, mode) do
    case Client.patch(@path, %{"key" => key, "value" => value}) do
      {:ok, body} ->
        if mode == :json, do: Output.emit_json(body), else: print_item(body["data"])

      {:error, err} ->
        Output.die(err)
    end
  end

  defp schema(mode) do
    body = fetch!(%{})

    if mode == :json do
      Output.emit_json(body)
    else
      for i <- body["data"] do
        IO.puts("#{i["key"]}  (#{i["type"]})")
        IO.puts("    #{i["description"]}")
        if i["allowed"], do: IO.puts("    allowed: #{Enum.join(i["allowed"], ", ")}")
      end
    end
  end

  defp fetch!(params) do
    case Client.get(@path, Map.to_list(params)) do
      {:ok, body} -> body
      {:error, err} -> Output.die(err)
    end
  end

  # The same value rule as `arb config set` (`Config.Value.parse_value/1`):
  # JSON when it parses (5, [..], [], null, "quoted"), otherwise the raw string
  # — the server then rejects it with the allowed values.
  defp parse(raw), do: Value.parse_value(raw)

  defp print_item(i) do
    source = if i["overridden"], do: "override", else: "default"
    IO.puts("#{i["key"]} = #{Jason.encode!(i["value"])}  (#{source})")
    IO.puts("    default: #{Jason.encode!(i["default"])}")
  end

  # Read-only: the autopilot is controlled with `arb scheduler`.
  defp print_autopilot do
    case Client.get("/api/scheduler/status") do
      {:ok, %{"paused" => paused}} ->
        state = if paused, do: "paused", else: "running"

        IO.puts(
          "autopilot = #{state}  (read-only here; control with `arb scheduler pause|resume`)"
        )

      _ ->
        :ok
    end
  end
end
