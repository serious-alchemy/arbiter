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
      arb node events <name|id> [--json]

  `add` and `set` need the operator's own token (the human's `arb`, not a
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
  @set_switches [name: :string, label: [:string, :keep], max_workers: :string]

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

      {:ok, %{"nodes" => []}} ->
        IO.puts("No nodes. Add one with `arb node add`.")

      {:ok, %{"nodes" => nodes}} ->
        IO.puts(
          row(["NAME", "STATUS", "WORKERS", "LAST SEEN", "LABELS"])
          |> String.trim_trailing()
        )

        for n <- nodes, do: IO.puts(row(node_cells(n)) |> String.trim_trailing())

      {:error, err} ->
        Output.die(err)
    end
  end

  defp node_cells(n) do
    [
      n["name"],
      n["status"],
      to_string(n["max_workers"] || "-"),
      n["last_seen_at"] || "never",
      Enum.join(n["labels"] || [], ",")
    ]
  end

  defp row(cells) do
    widths = [24, 10, 8, 26, 0]

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

  defp print_node(n) do
    IO.puts("#{n["name"]}")
    IO.puts("  id:            #{n["id"]}")
    IO.puts("  status:        #{n["status"]}")
    IO.puts("  max workers: #{n["max_workers"] || "unlimited"}")
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

    body =
      %{}
      |> put(:name, opts[:name])
      |> put(:labels, labels(opts))
      |> put_max_workers(opts[:max_workers])

    if body == %{},
      do: Output.die("arb node set: nothing to set (--name, --label, --max-workers)")

    case Client.patch(path(ref), stringify(body)) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, %{"node" => n}} -> IO.puts("Updated #{n["name"]}.")
      {:error, err} -> Output.die(err)
    end
  end

  defp put_max_workers(body, nil), do: body
  defp put_max_workers(body, "none"), do: Map.put(body, :max_workers, nil)

  defp put_max_workers(body, value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> Map.put(body, :max_workers, n)
      _ -> Output.die("--max-workers must be a positive number, or `none`")
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp ref!([ref | _], _verb) when is_binary(ref) and ref != "", do: ref
  defp ref!(_, verb), do: Output.die("arb node #{verb}: a node name or id is required")

  defp path(ref), do: "/api/nodes/" <> URI.encode(ref, &URI.char_unreserved?/1)

  defp put(map, _key, nil), do: map
  defp put(map, _key, []), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp labels(opts), do: Keyword.get_values(opts, :label)

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
