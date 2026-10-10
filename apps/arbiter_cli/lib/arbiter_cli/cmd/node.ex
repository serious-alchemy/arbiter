defmodule ArbiterCli.Cmd.Node do
  @moduledoc """
  `arb node` — remote worker nodes (`docs/design/remote-workers.md` §5.6).

      arb node add    [--name N] [--label k=v ...] [--max-workers N] [--ttl 15m]
                      [--token-file PATH] [--json]
                      mint a single-use join token. Prints the command to run
                      on the new node (it carries no secret) and, separately,
                      the token: to a terminal, or to --token-file (mode 0600).
                      It never prints the token to a pipe or a log.
      arb node add    --kind cluster --name N [--namespace NS] [--max-workers N]
                      [--cpu Q] [--memory Q] [--node-selector k=v,k=v]
                      [--pull-secret NAME] [--reach direct|tailscale]
                      [--admission policy] [--self-upgrade on|off] [--ttl 15m]
                      [-o manifests.yaml] [--token-file PATH] [--json]
                      add a Kubernetes cluster as a node. Prints the `kubectl
                      apply` for the install manifests (they carry no secret; -o
                      saves them to a file instead) and the command that creates
                      the join Secret with the token read from the terminal
                      (`read -rs`), so it is never in shell history or argv.
      arb node pending [--json]                         (device-code pairing requests waiting)
      arb node approve <code> [--name N] [--max-workers N] [--yes] [--json]
                      approve the pairing request showing <code> (XXXX-XXXX) on
                      a new node. Shows its hostname and source address first
                      and asks, unless --yes. The node then collects its own
                      credential; nothing long is typed anywhere.
      arb node deny   <code>                             (refuse a pairing request)
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
  itself (which the override cannot beat) and its last heartbeat, then the
  capacity breakdown, `capacity N = local a + node b`: the sum of every
  available machine's cap. The primary's own cap defaults to its hardware
  suggestion and is enforced like any node's. `drain` stops new
  work, `revoke` cuts the node off, `upgrade` asks a connected node to move to
  the release this install serves. Each writes a node event (`arb node events`).

  Everything but `list`, `show` and `events` — and those too — needs the operator's own token (the human's `arb`, not a
  coordinator session): enrolling a machine hands it provider credentials.
  Two ways to enrol a node:

    * **Pairing (interactive):** on the new node run `curl -fsSL <primary>/join |
      bash`. It prints a short code; run `arb node approve <code>` here (or
      approve it on the dashboard's Nodes page). The code is not a secret: it
      only says which request you mean. Approve only a code you can see on a
      machine you recognise, and check the hostname and address `approve` shows.
      A request expires in 10 minutes and works once.
    * **Join token (unattended):** `arb node add` mints a single-use token; give
      the node `ARB_JOIN_TOKEN_FILE=<path>` (or `ARB_JOIN_MODE=token` to type it
      at a prompt).
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @add_switches [
    name: :string,
    label: [:string, :keep],
    max_workers: :integer,
    ttl: :string,
    token_file: :string,
    kind: :string,
    namespace: :string,
    cpu: :string,
    memory: :string,
    node_selector: :string,
    pull_secret: :string,
    reach: :string,
    admission: :string,
    self_upgrade: :string,
    output: :string
  ]
  @cluster_only ~w(namespace cpu memory node_selector pull_secret reach admission self_upgrade output)a
  @set_switches [
    name: :string,
    label: [:string, :keep],
    max_workers: :string,
    workspace: [:string, :keep],
    allow_unenforced_network: :boolean
  ]

  @approve_switches [name: :string, max_workers: :integer, yes: :boolean]

  @verbs ~w(drain undrain revoke upgrade remove)

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      dispatch(Output.drop_json(argv), Output.mode(argv))
    end
  end

  defp dispatch(["add" | rest], mode), do: add(rest, mode)
  defp dispatch(["approve" | rest], mode), do: approve(rest, mode)
  defp dispatch(["set" | rest], mode), do: set(rest, mode)

  defp dispatch(["pending" | rest], mode) do
    _ = positional!(rest, "arb node pending")
    pending(mode)
  end

  defp dispatch(["deny" | rest], mode), do: deny(positional!(rest, "arb node deny"), mode)

  defp dispatch(["list" | rest], mode) do
    _ = positional!(rest, "arb node list")
    list(mode)
  end

  defp dispatch(["show" | rest], mode), do: show(positional!(rest, "arb node show"), mode)

  defp dispatch(["events" | rest], mode),
    do: events(positional!(rest, "arb node events"), mode)

  defp dispatch([verb | rest], mode) when verb in @verbs,
    do: verb(verb, positional!(rest, "arb node #{verb}"), mode)

  defp dispatch(_argv, _mode) do
    IO.puts(:stderr, "arb: unknown node subcommand")
    IO.puts(:stderr, "Run `arb node --help` for usage.")
    Output.halt(2)
  end

  # The positional args of a verb that takes no flags of its own: anything
  # flag-shaped is an error rather than a node reference.
  defp positional!(args, command) do
    {_opts, rest, _mode} = ArgParser.parse(args, command: command, switches: [])
    rest
  end

  # ---- add -------------------------------------------------------------------

  defp add(argv, mode) do
    {opts, _rest, _} =
      ArgParser.parse_strict!(argv, "arb node add", strict: @add_switches, aliases: [o: :output])

    case opts[:kind] || "machine" do
      "machine" -> add_machine(opts, mode)
      "cluster" -> add_cluster(opts, mode)
      other -> Output.die("--kind must be machine or cluster, not #{inspect(other)}")
    end
  end

  defp add_machine(opts, mode) do
    for flag <- @cluster_only, opts[flag] != nil do
      Output.die("--#{flag |> to_string() |> String.replace("_", "-")} needs --kind cluster")
    end

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

  # ---- add --kind cluster (K9) ----------------------------------------------------

  defp add_cluster(opts, mode) do
    name =
      opts[:name] ||
        Output.die(
          "--name is required with --kind cluster",
          "the install manifests and the join token are bound to the node's name"
        )

    # Decide where the token and the manifests go before minting anything.
    output = manifests_sink!(opts[:output])
    sink = token_sink!(opts[:token_file])

    body =
      %{kind: "cluster", name: name}
      |> put(:namespace, opts[:namespace])
      |> put(:max_workers, opts[:max_workers])
      |> put(:cpu, opts[:cpu])
      |> put(:memory, opts[:memory])
      |> put(:node_selector, opts[:node_selector])
      |> put(:pull_secret, opts[:pull_secret])
      |> put(:reach, opts[:reach])
      |> put(:admission, opts[:admission])
      |> put(:self_upgrade, opts[:self_upgrade])
      |> put(:ttl_seconds, ttl(opts[:ttl]))

    case Client.post("/api/nodes/join-tokens", stringify(body)) do
      {:ok, resp} -> deliver_cluster(resp, sink, output, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp manifests_sink!(nil), do: nil

  defp manifests_sink!(path) do
    if File.exists?(path), do: Output.die("-o #{path} already exists; not overwriting")
    path
  end

  defp deliver_cluster(resp, sink, output, mode) do
    cluster = resp["cluster"] || %{}
    token = resp["token"]
    expires = get_in(resp, ["join_token", "expires_at"])

    token_file =
      case sink do
        {:file, path} -> write_token!(path, token)
        :tty -> nil
      end

    manifests = save_manifests(cluster, output)

    if mode == :json do
      out =
        %{"expires_at" => expires, "join_token" => resp["join_token"], "cluster" => cluster}
        |> put_json("manifests_file", manifests)

      Output.emit_json(
        if token_file,
          do: Map.put(out, "token_file", token_file),
          else: Map.put(out, "token", token)
      )
    else
      print_cluster(cluster, expires, token, token_file, manifests)
    end
  end

  # The manifests hold no secret, so they are fetched from the primary like `kubectl apply -f
  # <(curl ...)` would. A failed fetch does not waste the token: the apply command still works.
  defp save_manifests(_cluster, nil), do: nil

  defp save_manifests(cluster, path) do
    with url when is_binary(url) <- cluster["manifest_url"],
         {:ok, yaml} when is_binary(yaml) <- Client.probe_url(url, decode_body: false),
         :ok <- File.write(path, yaml, [:exclusive]) do
      path
    else
      other ->
        IO.puts(
          :stderr,
          "arb: could not save the manifests to #{path} (#{inspect(other)}); " <>
            "use the apply command below instead"
        )

        nil
    end
  end

  defp put_json(map, _key, nil), do: map
  defp put_json(map, key, value), do: Map.put(map, key, value)

  defp print_cluster(cluster, expires, token, token_file, manifests) do
    IO.puts("Join token minted (expires #{expires || "soon"}). It works once.")
    IO.puts("")
    IO.puts("1. Install the manifests (cluster-admin, once). They contain no secret:")
    IO.puts("")

    IO.puts(
      "  #{if manifests, do: "kubectl apply -f #{manifests}", else: cluster["apply_command"]}"
    )

    IO.puts("")

    if token_file do
      IO.puts("2. Create the join Secret from the token file (#{token_file}, mode 0600):")
      IO.puts("")

      IO.puts(
        "  kubectl -n #{cluster["namespace"]} create secret generic arbiter-join " <>
          "--from-file=token=#{token_file}"
      )
    else
      IO.puts("2. Create the join Secret. The command asks for the token without echoing it,")
      IO.puts("   so it is never in your shell history or a process list:")
      IO.puts("")
      IO.puts("  #{cluster["secret_command"]}")
      IO.puts("")
      IO.puts("3. When it asks, enter this token (shown once):")
      IO.puts("")
      IO.puts("  #{token}")
    end

    IO.puts("")
    IO.puts("Once the controller is up, `arb node list` shows it. The Secret is spent after")

    IO.puts(
      "first boot: delete it with `kubectl -n #{cluster["namespace"]} delete secret arbiter-join`."
    )
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
      IO.puts("  #{token_file_liner(liner, token_file)}")
    else
      IO.puts("2. When the script asks, enter this token (shown once; never put it on a")
      IO.puts("   command line):")
      IO.puts("")
      IO.puts("  #{token}")
    end
  end

  # The env var has to sit on the `bash` side of the pipe: `VAR=x curl ... | bash`
  # would hand it to curl and the script would never see it. The server's
  # one-liner ends in `ARB_JOIN_MODE=token bash`; swap that for the file.
  defp token_file_liner(liner, token_file) do
    String.replace(
      liner,
      ~r/ARB_JOIN_MODE=token bash\z/,
      "ARB_JOIN_TOKEN_FILE=#{token_file} bash"
    )
  end

  # ---- pairing (device code) --------------------------------------------------

  defp pending(mode) do
    case Client.get("/api/nodes/pairings") do
      {:ok, resp} when mode == :json ->
        Output.emit_json(resp)

      {:ok, %{"pairings" => []}} ->
        IO.puts(
          "No pending pairing requests. On the new node run: curl -fsSL <primary>/join | bash"
        )

      {:ok, %{"pairings" => rows}} ->
        IO.puts(
          pairing_row(["CODE", "HOSTNAME", "FROM", "EXPIRES", "NAME"])
          |> String.trim_trailing()
        )

        for r <- rows, do: IO.puts(pairing_row(pairing_cells(r)) |> String.trim_trailing())
        IO.puts("\nApprove one with: arb node approve <code>")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp pairing_cells(r),
    do: [r["code"], r["hostname"], r["peer"], r["expires_at"], r["name"] || "-"]

  defp pairing_row(cells) do
    cells
    |> Enum.zip([11, 26, 40, 26, 0])
    |> Enum.map_join("  ", fn {cell, w} -> String.pad_trailing(to_string(cell), w) end)
  end

  defp approve(argv, mode) do
    {opts, rest, _} =
      ArgParser.parse_strict!(argv, "arb node approve", strict: @approve_switches)

    typed = pairing_ref!(rest, "approve")
    yes? = opts[:yes] == true

    if mode == :json and not yes?,
      do: Output.die("arb node approve --json needs --yes (there is no prompt in JSON mode)")

    req = find_pairing!(typed)
    body = %{} |> put(:name, opts[:name]) |> put(:max_workers, opts[:max_workers])

    unless yes? do
      print_pairing(req, opts)
      confirm_approve!(req)
    end

    case Client.post(pairing_path(req, "approve"), stringify(body)) do
      {:ok, resp} when mode == :json ->
        Output.emit_json(resp)

      {:ok, _} ->
        IO.puts(
          "Approved #{req["code"]} (#{req["hostname"]}, #{req["peer"]}). The node will collect its credential within a few seconds."
        )

      {:error, err} ->
        Output.die(err)
    end
  end

  defp deny(argv, mode) do
    req = find_pairing!(pairing_ref!(argv, "deny"))

    case Client.post(pairing_path(req, "deny"), %{}) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, _} -> IO.puts("Denied #{req["code"]} (#{req["hostname"]}, #{req["peer"]}).")
      {:error, err} -> Output.die(err)
    end
  end

  defp pairing_ref!([ref | _], _verb) when is_binary(ref) and ref != "", do: ref

  defp pairing_ref!(_, verb),
    do: Output.die("arb node #{verb}: the pairing code the node shows is required")

  defp pairing_path(req, verb),
    do: "/api/nodes/pairings/" <> URI.encode(req["id"], &URI.char_unreserved?/1) <> "/" <> verb

  # The pending request whose code matches what was typed (case, dashes and
  # spaces ignored), so the operator always sees what they are approving.
  defp find_pairing!(typed) do
    wanted = normalize_code(typed)

    case Client.get("/api/nodes/pairings") do
      {:ok, %{"pairings" => rows}} ->
        Enum.find(rows, &(normalize_code(&1["code"]) == wanted)) ||
          Output.die(
            "no pending pairing request with code #{typed}",
            "list them with `arb node pending`; a request lasts 10 minutes"
          )

      {:error, err} ->
        Output.die(err)
    end
  end

  defp normalize_code(code),
    do: code |> to_string() |> String.replace(~r/[\s-]/, "") |> String.upcase()

  defp print_pairing(req, opts) do
    IO.puts("Pairing request #{req["code"]}")
    IO.puts("  hostname:    #{req["hostname"]}   (the node's own claim)")
    IO.puts("  from:        #{req["peer"]}   (the address the primary saw)")
    IO.puts("  name:        #{opts[:name] || req["name"] || "(generated)"}")
    IO.puts("  expires:     #{req["expires_at"]}")
    IO.puts("")
    IO.puts("Approving gives this machine access to run workers with this install's")
    IO.puts("provider credentials. Approve only if the code is on a screen you are looking at.")
  end

  defp confirm_approve!(req) do
    answer =
      IO.gets("Approve #{req["code"]} from #{req["hostname"]} (#{req["peer"]})? [y/N] ")
      |> to_string()
      |> String.trim()

    unless answer in ["y", "Y", "yes"] do
      IO.puts("aborted")
      Output.halt(0)
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
            "VERSION",
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
    [
      n["name"],
      n["state"],
      dash(n["agent_version"]),
      live_max(n),
      dash(n["suggested"]),
      dash(n["override"]),
      "-",
      "-",
      ""
    ]
  end

  defp node_cells(n) do
    [
      n["name"],
      n["state"] || n["status"],
      dash(n["agent_version"]),
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

  defp print_totals(%{"local" => %{"max" => _}, "total" => _} = resp) do
    IO.puts("")
    IO.puts(capacity_line(resp))
    if advisory = resp["local_cap_advisory"], do: IO.puts("note: " <> advisory)

    for w <- resp["warnings"] || [], do: IO.puts("warning: " <> warning(w, resp))
  end

  defp print_totals(_), do: :ok

  @doc """
  `capacity N = local a + box-1 b`: the install's capacity broken down by
  machine (RW14). Only machines that add something are summed; the ones that
  do not (offline, draining, revoked, lost) are listed after it with why.
  Shared with `arb server doctor`.
  """
  @spec capacity_line(map()) :: String.t()
  def capacity_line(%{"local" => %{"max" => local}, "total" => total} = resp) do
    {adding, idle} =
      Enum.split_with(resp["nodes"] || [], &((&1["contributes"] || 0) > 0))

    parts = ["local #{local}"] ++ Enum.map(adding, &"#{&1["name"]} #{&1["contributes"]}")
    line = "capacity #{total} = #{Enum.join(parts, " + ")}"

    case idle do
      [] -> line
      _ -> line <> " (not counted: " <> Enum.map_join(idle, ", ", &idle_phrase/1) <> ")"
    end
  end

  defp idle_phrase(n), do: "#{n["name"]} #{n["state"] || n["status"] || "unavailable"}"

  defp warning("local_cap_zero", _),
    do:
      "the local cap is 0: work that can only run on this machine (reviewers, fix and " <>
        "conflict passes, agy/codex, research) will wait"

  defp warning(other, _), do: other

  defp row(cells) do
    widths = [24, 10, 10, 9, 10, 9, 8, 26, 0]

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
    IO.puts("  version:       #{n["agent_version"] || "-"}")
    IO.puts("  max workers: #{n["max"] || n["max_workers"] || "unknown"}#{cap_detail(n)}")
    IO.puts("  pinned to:     #{pinned(n["workspace_ids"])}")
    IO.puts("  labels:        #{Enum.join(n["labels"] || [], ", ")}")
    IO.puts("  credential:    #{n["credential_prefix"] || "-"}…")
    IO.puts("  enrolled:      #{n["enrolled_at"]}")
    IO.puts("  last seen:     #{n["last_seen_at"] || "never"}")
    if n["revoked_at"], do: IO.puts("  revoked:       #{n["revoked_at"]}")
    print_cluster(n)
  end

  # K9: a cluster node's kind and Kubernetes version, and, when it is behind, how it moves: by
  # itself (it can patch its own Deployment) or by this exact command.
  defp print_cluster(%{"kind" => "cluster"} = n) do
    IO.puts("  kind:          cluster")
    if n["k8s_version"], do: IO.puts("  Kubernetes:    #{n["k8s_version"]}")

    cond do
      n["upgrade_command"] ->
        IO.puts("")
        IO.puts("  This controller is #{n["health"]}: it cannot patch its own Deployment, so no")
        IO.puts("  work is placed on it until it runs this server's version. Run:")
        IO.puts("")
        IO.puts("  #{n["upgrade_command"]}")

      n["self_upgrade"] == true and n["health"] in ["outdated", "ahead"] ->
        IO.puts(
          "  upgrade:       this controller upgrades itself (to #{n["image"] || "this server's image"})"
        )

      true ->
        :ok
    end
  end

  defp print_cluster(_n), do: :ok

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

  defp set(argv, mode) do
    {opts, rest, _} = ArgParser.parse_strict!(argv, "arb node set", strict: @set_switches)
    ref = ref!(rest, "set")

    if ref == "local" and not local_applicable?(opts),
      do: Output.die("arb node set local: only --max-workers applies to local")

    body =
      %{}
      |> put(:name, opts[:name])
      |> put(:labels, labels(opts))
      |> put_pins(pins(opts))
      |> put_max_workers(opts[:max_workers], ref == "local")
      |> put_flag(:allow_unenforced_network, opts[:allow_unenforced_network])

    if body == %{},
      do:
        Output.die(
          "arb node set: nothing to set " <>
            "(--name, --label, --max-workers, --workspace, --allow-unenforced-network)"
        )

    case Client.patch(path(ref), stringify(body)) do
      {:ok, resp} when mode == :json -> Output.emit_json(resp)
      {:ok, %{"node" => n}} -> IO.puts("Updated #{n["name"]}.")
      {:error, err} -> Output.die(err)
    end
  end

  # The primary has a cap and nothing else to set.
  defp local_applicable?(opts),
    do:
      is_nil(opts[:name]) and labels(opts) == [] and pins(opts) == [] and
        is_nil(opts[:allow_unenforced_network])

  # `--workspace none` clears the pin (any workspace may run on the node).
  defp put_pins(body, []), do: body
  defp put_pins(body, ["none"]), do: Map.put(body, :workspace_ids, [])
  defp put_pins(body, ids), do: Map.put(body, :workspace_ids, ids)

  # A7: `--allow-unenforced-network` / `--no-allow-unenforced-network` (a cluster node whose
  # NetworkPolicy is not enforced is only used when the operator says so; audited server-side).
  defp put_flag(body, _key, nil), do: body
  defp put_flag(body, key, value) when is_boolean(value), do: Map.put(body, key, value)

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
