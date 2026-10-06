defmodule ArbiterCli.Cmd.Node do
  @moduledoc """
  `arb node` — remote worker nodes (`docs/design/remote-workers.md` §5.6).

      arb node add    [--name N] [--label k=v ...] [--max-workers N] [--ttl 15m]
                      [--token-file PATH] [--json]
                      mint a single-use join token. Prints the command to run
                      on the new node (it carries no secret) and, separately,
                      the token: to a terminal, or to --token-file (mode 0600).
                      It never prints the token to a pipe or a log.
      arb node list   [--json]
      arb node show   <name|id> [--json]
      arb node set    <name|id> [--name N] [--label k=v ...] [--max-workers N|none]
                      [--workspace ID ... | --workspace none]   (pin: only these workspaces run here)
      arb node set    local --max-workers N|none       (N may be 0: nodes do the work)
      arb node events <name|id> [--json]
      arb node drain|undrain|revoke|upgrade <name|id>
      arb node remove <name|id>                        (a revoked node only)

  `list` shows the primary first as `local`, then each node's state, live/max
  capacity, the node's own suggestion, your override, any ceiling set on the node
  itself (which the override cannot beat) and its last heartbeat, with
  `local + Σ remote caps` against `conductor.max_concurrent`. `drain` stops new
  work, `revoke` cuts the node off, `upgrade` asks a connected node to move to
  the release this install serves. Each writes a node event (`arb node events`).

  Everything but `list`, `show` and `events` — and those too — needs the operator's own token (the human's `arb`, not a
  coordinator session): enrolling a machine hands it provider credentials.
  The node enrols by running the printed command; the token is typed at its
  prompt, or supplied with `ARB_JOIN_TOKEN_FILE=<path>` for unattended installs.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @add_switches [
    name: :string,
    label: [:string, :keep],
    max_workers: :integer,
    ttl: :string,
    token_file: :string
  ]
  @set_switches [
    name: :string,
    label: [:string, :keep],
    max_workers: :string,
    workspace: [:string, :keep]
  ]

  @verbs ~w(drain undrain revoke upgrade remove)

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      case Output.drop_json(argv) do
        ["add" | rest] ->
          add(rest, Output.mode(argv))

        ["list" | _] ->
          list(Output.mode(argv))

        ["show" | rest] ->
          show(rest, Output.mode(argv))

        ["set" | rest] ->
          set(rest, Output.mode(argv))

        ["events" | rest] ->
          events(rest, Output.mode(argv))

        [verb | rest] when verb in @verbs ->
          verb(verb, rest, Output.mode(argv))

        _ ->
          IO.puts(:stderr, "arb: unknown node subcommand")
          IO.puts(:stderr, "Run `arb node --help` for usage.")
          Output.halt(2)
      end
    end
  end

  # ---- add -------------------------------------------------------------------

  defp add(argv, mode) do
    {opts, _rest, _} = ArgParser.parse_strict!(argv, "arb node add", strict: @add_switches)

    body =
      %{}
      |> put(:name, opts[:name])
      |> put(:labels, labels(opts))
      |> put(:max_workers, opts[:max_workers])
      |> put(:ttl_seconds, ttl(opts[:ttl]))

    # Decide where the token will go before minting one: a token with nowhere
    # safe to be shown would be minted for nothing.
    sink = token_sink!(opts[:token_file])

    case Client.post("/api/nodes/join-tokens", stringify(body)) do
      {:ok, resp} -> deliver(resp, sink, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp token_sink!(path) when is_binary(path) do
    if File.exists?(path), do: Output.die("--token-file #{path} already exists; not overwriting")
    {:file, path}
  end

  defp token_sink!(nil) do
    if stdout_tty?() do
      :tty
    else
      Output.die(
        "refusing to print the join token to a pipe or file",
        "pass --token-file PATH (written mode 0600), or run `arb node add` in a terminal"
      )
    end
  end

  defp stdout_tty? do
    case Process.get(:bd2_stdout_tty) do
      nil -> real_tty?()
      value -> value
    end
  end

  defp real_tty? do
    :prim_tty.isatty(:stdout) == true
  rescue
    _ -> false
  end

  defp deliver(resp, sink, mode) do
    token = resp["token"]
    expires = get_in(resp, ["join_token", "expires_at"])
    liner = resp["one_liner"]

    token_file =
      case sink do
        {:file, path} -> write_token!(path, token)
        :tty -> nil
      end

    if mode == :json do
      out = %{"one_liner" => liner, "expires_at" => expires, "join_token" => resp["join_token"]}

      out =
        if token_file,
          do: Map.put(out, "token_file", token_file),
          else: Map.put(out, "token", token)

      Output.emit_json(out)
    else
      print_instructions(liner, expires, token, token_file)
    end
  end

  defp write_token!(path, token) do
    File.write!(path, token <> "\n", [:exclusive])
    File.chmod!(path, 0o600)
    path
  rescue
    e -> Output.die("could not write --token-file #{path}", Exception.message(e))
  end

  defp print_instructions(liner, expires, token, token_file) do
    IO.puts("Join token minted (expires #{expires || "soon"}). It works once.")
    IO.puts("")
    IO.puts("1. On the new node, as the user that will own it (not root), run this.")
    IO.puts("   It contains no secret:")
    IO.puts("")
    IO.puts("  #{liner}")
    IO.puts("")

    if token_file do
      IO.puts("2. The token is in #{token_file} (mode 0600), not printed. For an unattended")
      IO.puts("   install, copy the file to the node and run:")
      IO.puts("")
      IO.puts("  ARB_JOIN_TOKEN_FILE=#{token_file} #{liner}")
    else
      IO.puts("2. When the script asks, enter this token (shown once; never put it on a")
      IO.puts("   command line):")
      IO.puts("")
      IO.puts("  #{token}")
    end
  end

  # ---- list / show / events --------------------------------------------------

  defp list(mode) do
    case Client.get("/api/nodes") do
      {:ok, resp} when mode == :json ->
        Output.emit_json(resp)

      {:ok, %{"nodes" => []} = resp} when not is_map_key(resp, "local") ->
        IO.puts("No nodes. Add one with `arb node add`.")

      {:ok, %{"nodes" => nodes} = resp} ->
        rows = Enum.reject([resp["local"]], &is_nil/1) ++ nodes

        IO.puts(
          row([
            "NAME",
            "STATE",
            "LIVE/MAX",
            "SUGGESTED",
            "OVERRIDE",
            "CEILING",
            "LAST HEARTBEAT",
            "LABELS"
          ])
          |> String.trim_trailing()
        )

        for n <- rows, do: IO.puts(row(node_cells(n)) |> String.trim_trailing())
        print_totals(resp)
        if nodes == [], do: IO.puts("\nNo remote nodes. Add one with `arb node add`.")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp node_cells(%{"kind" => "local"} = n) do
    [n["name"], n["state"], live_max(n), dash(n["suggested"]), dash(n["override"]), "-", "-", ""]
  end

  defp node_cells(n) do
    [
      n["name"],
      n["state"] || n["status"],
      live_max(n),
      dash(n["suggested"]),
      dash(n["override"] || n["max_workers"]),
      dash(n["ceiling"]),
      n["last_heartbeat_at"] || n["last_seen_at"] || "never",
      Enum.join(n["labels"] || [], ",")
    ]
  end

  defp live_max(%{"live" => live, "max" => max}), do: "#{live}/#{max || "?"}"
  defp live_max(_), do: "-"

  defp dash(nil), do: "-"
  defp dash(value), do: to_string(value)

  defp print_totals(
         %{"local" => %{"max" => local}, "total" => total, "ceiling" => ceiling} = resp
       ) do
    IO.puts("")

    IO.puts(
      "local #{local} + nodes #{total - local} = #{total}, against conductor.max_concurrent = #{ceiling}"
    )

    for w <- resp["warnings"] || [], do: IO.puts("warning: " <> warning(w, resp))
  end

  defp print_totals(_), do: :ok

  defp warning("local_cap_zero", _),
    do:
      "the local cap is 0: work that can only run on this machine (reviewers, fix and " <>
        "conflict passes, agy/codex, research) will wait"

  defp warning("ceiling_below_total", resp),
    do:
      "conductor.max_concurrent (#{resp["ceiling"]}) is below #{resp["total"]}, the sum " <>
        "of the caps: the extra capacity will sit idle"

  defp warning("ceiling_far_above_total", resp),
    do:
      "conductor.max_concurrent (#{resp["ceiling"]}) is far above #{resp["total"]}, the sum " <>
        "of the caps: the board will plan more than any machine can start"

  defp warning(other, _), do: other

  defp row(cells) do
    widths = [24, 10, 9, 10, 9, 8, 26, 0]

    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(to_string(cell), w) end)
  end

  defp show(argv, mode) do
    ref = ref!(argv, "show")

    case Client.get(path(ref)) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, %{"node" => n}} -> print_node(n)
      {:error, err} -> Output.die(err)
    end
  end

  # Where the effective cap came from: the node's suggestion, your override, and
  # a ceiling set on the node itself, which wins over an override above it.
  defp cap_detail(n) do
    parts =
      [
        n["suggested"] && "suggested #{n["suggested"]}",
        n["override"] && "override #{n["override"]}",
        n["ceiling"] && "ceiling #{n["ceiling"]}"
      ]
      |> Enum.filter(& &1)

    suffix = if n["cap_source"] == "ceiling", do: " — the ceiling wins", else: ""
    if parts == [], do: "", else: " (#{Enum.join(parts, ", ")}#{suffix})"
  end

  defp pinned(ids) when is_list(ids) and ids != [], do: Enum.join(ids, ", ")
  defp pinned(_), do: "any workspace"

  defp print_node(n) do
    IO.puts("#{n["name"]}")
    IO.puts("  id:            #{n["id"]}")
    IO.puts("  status:        #{n["status"]}")
    IO.puts("  max workers: #{n["max"] || n["max_workers"] || "unknown"}#{cap_detail(n)}")
    IO.puts("  pinned to:     #{pinned(n["workspace_ids"])}")
    IO.puts("  labels:        #{Enum.join(n["labels"] || [], ", ")}")
    IO.puts("  credential:    #{n["credential_prefix"] || "-"}…")
    IO.puts("  enrolled:      #{n["enrolled_at"]}")
    IO.puts("  last seen:     #{n["last_seen_at"] || "never"}")
    if n["revoked_at"], do: IO.puts("  revoked:       #{n["revoked_at"]}")
  end

  defp events(argv, mode) do
    ref = ref!(argv, "events")

    case Client.get(path(ref) <> "/events") do
      {:ok, resp} when mode == :json ->
        Output.emit_json(resp)

      {:ok, %{"events" => []}} ->
        IO.puts("No events.")

      {:ok, %{"events" => events}} ->
        for e <- events, do: IO.puts(event_line(e))

      {:error, err} ->
        Output.die(err)
    end
  end

  defp event_line(e) do
    detail = if e["detail"] in [nil, %{}], do: "", else: " " <> Jason.encode!(e["detail"])
    hint = if e["remote_addr_hint"], do: " from #{e["remote_addr_hint"]}", else: ""

    "#{e["at"]}  #{String.pad_trailing(to_string(e["kind"]), 12)} #{e["actor"] || "-"}#{hint}#{detail}"
  end

  # ---- set -------------------------------------------------------------------

  defp set(argv, _mode) do
    {opts, rest, mode} = ArgParser.parse_strict!(argv, "arb node set", strict: @set_switches)
    ref = ref!(rest, "set")

    if ref == "local" and (opts[:name] || labels(opts) != [] || pins(opts) != []),
      do: Output.die("arb node set local: only --max-workers applies to local")

    body =
      %{}
      |> put(:name, opts[:name])
      |> put(:labels, labels(opts))
      |> put_pins(pins(opts))
      |> put_max_workers(opts[:max_workers], ref == "local")

    if body == %{},
      do: Output.die("arb node set: nothing to set (--name, --label, --max-workers, --workspace)")

    case Client.patch(path(ref), stringify(body)) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, %{"node" => n}} -> IO.puts("Updated #{n["name"]}.")
      {:error, err} -> Output.die(err)
    end
  end

  # `--workspace none` clears the pin (any workspace may run on the node).
  defp put_pins(body, []), do: body
  defp put_pins(body, ["none"]), do: Map.put(body, :workspace_ids, [])
  defp put_pins(body, ids), do: Map.put(body, :workspace_ids, ids)

  defp put_max_workers(body, nil, _local?), do: body
  defp put_max_workers(body, "none", _local?), do: Map.put(body, :max_workers, nil)

  defp put_max_workers(body, value, local?) do
    min = if local?, do: 0, else: 1

    case Integer.parse(value) do
      {n, ""} when n >= min ->
        Map.put(body, :max_workers, n)

      _ when local? ->
        Output.die("--max-workers must be 0 or more, or `none`")

      _ ->
        Output.die("--max-workers must be a positive number, or `none` (drain a node to stop it)")
    end
  end

  # ---- drain / undrain / revoke / upgrade / remove ---------------------------

  defp verb("remove", argv, mode) do
    ref = ref!(argv, "remove")

    case Client.delete(path(ref)) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, _} -> IO.puts("Removed #{ref}.")
      {:error, err} -> Output.die(err)
    end
  end

  defp verb(verb, argv, mode) do
    ref = ref!(argv, verb)

    case Client.post(path(ref) <> "/" <> verb, %{}) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, resp} -> IO.puts(done_line(verb, resp["node"]["name"] || ref, resp))
      {:error, err} -> Output.die(err)
    end
  end

  defp done_line("drain", name, _), do: "Draining #{name}: no new work; its live runs continue."
  defp done_line("undrain", name, _), do: "Undrained #{name}."
  defp done_line("revoke", name, _), do: "Revoked #{name}: its credential no longer works."

  defp done_line("upgrade", name, resp),
    do:
      "Upgrade requested for #{name}" <>
        if(resp["upgrading_to"], do: " (to #{resp["upgrading_to"]}).", else: ".")

  # ---- helpers ---------------------------------------------------------------

  defp ref!([ref | _], _verb) when is_binary(ref) and ref != "", do: ref
  defp ref!(_, verb), do: Output.die("arb node #{verb}: a node name or id is required")

  defp path(ref), do: "/api/nodes/" <> URI.encode(ref, &URI.char_unreserved?/1)

  defp put(map, _key, nil), do: map
  defp put(map, _key, []), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp labels(opts), do: Keyword.get_values(opts, :label)
  defp pins(opts), do: Keyword.get_values(opts, :workspace)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp ttl(nil), do: nil

  defp ttl(text) do
    case Regex.run(~r/\A(\d+)([smh])\z/, text) do
      [_, n, unit] when n != "0" ->
        String.to_integer(n) * %{"s" => 1, "m" => 60, "h" => 3600}[unit]

      _ ->
        Output.die("--ttl must be a positive duration like 90s, 15m or 2h (max 24h)")
    end
  end
end
