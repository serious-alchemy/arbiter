defmodule ArbiterCli.Cmd.Config do
  @moduledoc """
  `arb config` — safe, field-level access to a workspace's `config` JSON.

      arb config get      [dotted.key] [--workspace W] [--json]
      arb config set      <dotted.key> <value> [--workspace W] [--force]
      arb config unset    <dotted.key>         [--workspace W] [--force]
      arb config overview                       [--workspace W] [--json]
      arb config schema                         full config key reference

  `schema` prints a comprehensive reference of every top-level config key
  (tracker, merge, agent/review_agent, security, routing, review/review_gate,
  review_automation, quota, conductor, standing_orders, repo_paths, pr_patrol,
  review_patrol) with its sub-fields, valid enum values, and defaults — see
  `ArbiterCli.ConfigSchema` for the full text (also appended below).

  `overview` prints a human-readable summary of the workspace's config grouped
  into sections (tracker, merge, agent, routing, review, standing orders)
  rather than the raw JSON blob `get` emits. Secret *values* are never shown —
  only the names of configured secrets and any `credentials_ref` pointers.

  ## Background

  Until this command, the only ways to change config were `PATCH /api/workspaces/:id`
  (replace-the-whole-map semantics — a partial patch silently clobbered sibling
  keys) or raw SQL. `arb config set` and `arb config unset` go through
  `PATCH /api/workspaces/:id/config`, which **deep-merges** into the existing
  config so siblings are preserved.

  ## Value parsing

  `arb config set <key> <value>` decodes the value as JSON (the rule `arb
  settings set` uses too) and falls back to the raw string when it is not JSON:

    * `true` / `false` / `null`       → boolean / JSON null (use `unset` to remove)
    * a number                        → integer / float
    * `{...}` / `[...]`               → JSON object / array
    * a *quoted* string `'"true"'`    → that string, so `true`, `5` etc. can be
      stored as text: `arb config set feature.flag '"true"'`
    * anything else                   → the string as typed

  ## Key syntax

  Keys are dotted. A literal dot in a segment (a repo name) is written `\\.`:
  `arb config set 'repo_paths.my\\.repo' /srv/my.repo`.

  ## Guardrails

  The safety rails are enforced by the **server** (so MCP and REST get them
  too); the CLI only forwards `--force`:

    * top-level `secret*` / `credentials*` keys are refused — use
      `arb workspace secret` (secrets are stored encrypted, never in config)
    * a write that newly empties `repo_paths`, or sets `tracker.type != "none"`
      with `tracker.config` missing/empty, is refused unless `--force`
    * `unset` of an absent key is a no-op success

  Destructive changes (any unset, or any set that overwrites a non-empty
  existing leaf) print a before/after diff and need `--force`.

  ## Workspace selection

  By default targets the workspace resolved from `ARB_WORKSPACE` (or the one
  literally named `"default"`). Override per-invocation with
  `--workspace <name>`.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Output, Workspace}
  alias ArbiterCli.Cmd.Config.{Formatter, Value}

  @switches [workspace: :string, force: :boolean, json: :boolean]

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
      IO.puts("")
      IO.puts(ArbiterCli.ConfigSchema.render())
    else
      {opts, rest, mode} = ArgParser.parse(argv, command: "arb config", switches: @switches)
      workspace_opt = opts[:workspace]
      force = opts[:force] || false

      case rest do
        ["get" | rest] -> get(rest, workspace_opt, mode)
        ["set" | rest] -> set(rest, workspace_opt, force, mode)
        ["unset" | rest] -> unset(rest, workspace_opt, force, mode)
        ["overview" | _] -> overview(workspace_opt, mode)
        ["schema" | _] -> IO.puts(ArbiterCli.ConfigSchema.render())
        [] -> Output.die("config requires a subcommand: get, set, unset, overview, or schema")
        [unknown | _] -> Output.die("unknown config subcommand: #{unknown}")
      end
    end
  end

  # ----- get --------------------------------------------------------------

  defp get(args, workspace_opt, mode) do
    path =
      case args do
        [] -> nil
        [p] -> p
        _ -> Output.die("config get takes at most one positional argument: the dotted key")
      end

    ws = resolve_workspace!(workspace_opt)
    config = ws["config"] || %{}
    value = if path, do: Value.get_in_path(config, Value.split(path)), else: config

    case {mode, value} do
      {:json, v} -> Formatter.emit_get(:json, v, path)
      {:text, v} -> Formatter.emit_get(:text, v, path)
    end
  end

  # ----- overview ---------------------------------------------------------

  defp overview(workspace_opt, mode) do
    ws = resolve_workspace!(workspace_opt)
    config = ws["config"] || %{}
    Formatter.emit_overview(mode, ws, config)
  end

  # ----- set --------------------------------------------------------------

  defp set(args, workspace_opt, force, mode) do
    {key, raw_value} =
      case args do
        [k, v] -> {k, v}
        [k | rest] when rest != [] -> {k, Enum.join(rest, " ")}
        [_] -> Output.die("config set requires a value: arb config set <key> <value>")
        [] -> Output.die("config set requires <key> <value>")
      end

    path = Value.split(key)
    if path == [], do: Output.die("config set: key must not be empty")

    value = Value.parse_value(raw_value)
    patch = Value.put_in_path(%{}, path, value)

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}
    new_config = Value.deep_merge(existing, patch)

    confirm_or_die!(existing, new_config, force, "set #{key}")

    payload = with_force(%{"patch" => patch}, force)

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> Formatter.emit_workspace_config(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ----- unset ------------------------------------------------------------

  defp unset(args, workspace_opt, force, mode) do
    key =
      case args do
        [k] -> k
        [] -> Output.die("config unset requires a key: arb config unset <key>")
        _ -> Output.die("config unset takes exactly one argument: the dotted key")
      end

    path = Value.split(key)
    if path == [], do: Output.die("config unset: key must not be empty")

    ws = resolve_workspace!(workspace_opt)
    existing = ws["config"] || %{}

    # An absent key is not an error: the server treats it as an idempotent
    # no-op, the same as MCP and REST.
    new_config = Value.drop_path(existing, path)

    confirm_or_die!(existing, new_config, force, "unset #{key}")

    payload = with_force(%{"unset_paths" => [key]}, force)

    case Client.patch("/api/workspaces/" <> ws["id"] <> "/config", payload) do
      {:ok, updated} -> Formatter.emit_workspace_config(updated, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp with_force(payload, true), do: Map.put(payload, "force", true)
  defp with_force(payload, _), do: payload

  # ----- workspace resolution --------------------------------------------

  defp resolve_workspace!(nil) do
    case Workspace.resolve() do
      {:ok, ws} -> ws
      {:error, msg} -> Output.die(msg)
    end
  end

  defp resolve_workspace!(name) do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} ->
        case Enum.find(list, &(&1["name"] == name)) do
          nil -> Output.die("no workspace named #{inspect(name)}")
          ws -> ws
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  # ----- value parsing (public for tests) ---------------------------------

  @doc false
  defdelegate parse_value(raw), to: Value

  @doc false
  defdelegate split(path), to: Value

  @doc false
  defdelegate get_in_path(value, path), to: Value

  @doc false
  defdelegate put_in_path(map, path, value), to: Value

  @doc false
  defdelegate drop_path(map, path), to: Value

  @doc false
  defdelegate deep_merge(left, right), to: Value

  # ----- guardrails + diff -----------------------------------------------

  # The safety rails live on the server; this is only the overwrite prompt.
  defp confirm_or_die!(before, after_, force, label) do
    if destructive?(before, after_) and not force do
      IO.puts(:stderr, "arb config #{label}:")
      IO.puts(:stderr, Formatter.diff(before, after_))
      IO.puts(:stderr, "")
      IO.puts(:stderr, "this overwrites an existing value. Re-run with --force to apply.")
      Output.halt(1)
    else
      :ok
    end
  end

  defp destructive?(before, after_) do
    # A change is "destructive" if it removes a key that existed, or
    # overwrites a non-empty existing value with a different one.
    paths = collect_paths(before)

    Enum.any?(paths, fn p ->
      old = Value.get_in_path(before, p)
      new = Value.get_in_path(after_, p)

      cond do
        old in [nil, "", %{}, []] -> false
        new == old -> false
        new == nil -> true
        is_map(old) and is_map(new) -> false
        true -> true
      end
    end)
  end

  defp collect_paths(map, prefix \\ [])

  defp collect_paths(map, prefix) when is_map(map) do
    Enum.flat_map(map, fn {k, v} ->
      this = prefix ++ [to_string(k)]

      if is_map(v) and map_size(v) > 0 do
        [this | collect_paths(v, this)]
      else
        [this]
      end
    end)
  end

  defp collect_paths(_, _), do: []
end
