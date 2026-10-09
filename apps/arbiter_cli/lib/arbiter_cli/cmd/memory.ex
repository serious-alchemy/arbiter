defmodule ArbiterCli.Cmd.Memory do
  @moduledoc """
  The shared-memory operator surface (P-25): the promotion queue, quarantine
  and transcript distillation, over `/api/memory/*`.

      arb memory pending [--state pending|rejected]
                                        — candidates sessions wrote for the
                                          shared layer (default: the queue)
      arb memory diff <id>              — one candidate in full: its diff
                                          against the shared memory it would
                                          replace, and what promoting it would
                                          verify
      arb memory apply <id> [--overwrite]
                                        — promote a candidate into the shared
                                          layer every future session mounts
      arb memory reject <id> --reason "..."
                                        — reject it (kept, with the reason)
      arb memory quarantine             — memories the staleness checker pulled
                                          out of service, with why
      arb memory restore <name> [--reanchor]
                                        — re-verify a quarantined memory and
                                          serve it again if nothing is stale
      arb memory distill <session-id> [--max-bytes N] [--from-turn N]
                                        [--max-candidates N] [--max-cost-usd X]
                                        — propose candidates from an ended
                                          session's archived transcript (one
                                          metered model call; nothing reaches
                                          the shared layer). The bounds can
                                          only lower the configured caps.

  `<id>` is `<session-id>/<file>.md`, exactly as `pending` prints it.

  Operator only: every route needs a token minted over the operator socket,
  which `arb` does for you from your own shell. A coordinator session's token
  is refused, reads included.
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  @switches [
    state: :string,
    overwrite: :boolean,
    reason: :string,
    reanchor: :boolean,
    max_bytes: :integer,
    from_turn: :integer,
    max_candidates: :integer,
    max_cost_usd: :float
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} = ArgParser.parse(argv, command: "arb memory", switches: @switches)
      Workspace.reject_flag!("arb memory (the memory layer is installation-wide)")

      dispatch(rest, opts, mode)
    end
  end

  defp dispatch(["pending"], opts, mode), do: pending(opts, mode)
  defp dispatch(["diff" | args], _opts, mode), do: diff(args, mode)
  defp dispatch(["apply" | args], opts, mode), do: apply_candidate(args, opts, mode)
  defp dispatch(["reject" | args], opts, mode), do: reject(args, opts, mode)
  defp dispatch(["quarantine"], _opts, mode), do: quarantine(mode)
  defp dispatch(["restore" | args], opts, mode), do: restore(args, opts, mode)
  defp dispatch(["distill" | args], opts, mode), do: distill(args, opts, mode)
  defp dispatch(_rest, _opts, _mode), do: unknown()

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "arb: unknown memory subcommand")
    IO.puts(:stderr, "Run `arb memory --help` for usage.")
    Output.halt(2)
  end

  # ---- subcommands -------------------------------------------------------------

  defp pending(opts, mode) do
    params = if state = opts[:state], do: [state: state], else: []

    with_body(Client.get("/api/memory/pending", params), mode, fn body ->
      candidates = body["candidates"] || []
      state = opts[:state] || "pending"

      if candidates == [] do
        IO.puts("No #{state} memory candidates.")
      else
        IO.puts("#{String.upcase(state)} MEMORY CANDIDATES (#{length(candidates)})")
        Enum.each(candidates, &print_candidate/1)
      end
    end)
  end

  defp diff(args, mode) do
    id = one_arg!(args, "arb memory diff <id>", "id")

    with_body(Client.get("/api/memory/pending/diff", id: id), mode, fn body ->
      IO.puts("Candidate #{body["id"]}")
      print_verification(body["verification"])
      IO.puts("")

      case body["diff"] do
        nil ->
          IO.puts("(new memory: nothing in the shared layer to diff against)")
          IO.puts("")
          IO.puts(body["content"])

        diff ->
          IO.puts(diff)
      end
    end)
  end

  defp apply_candidate(args, opts, mode) do
    id = one_arg!(args, "arb memory apply <id>", "id")
    body = %{id: id, overwrite: opts[:overwrite] || false}

    with_body(Client.post("/api/memory/pending/apply", body), mode, fn resp ->
      IO.puts("Promoted #{resp["id"]} as shared memory #{resp["memory"]}.")
      print_verification(resp)
    end)
  end

  defp reject(args, opts, mode) do
    id = one_arg!(args, "arb memory reject <id> --reason \"...\"", "id")

    reason =
      opts[:reason] ||
        Output.die(
          "arb memory reject needs --reason \"...\"",
          "Say why, so the audit trail does."
        )

    with_body(
      Client.post("/api/memory/pending/reject", %{id: id, reason: reason}),
      mode,
      fn resp ->
        IO.puts("Rejected #{resp["id"]}; kept at #{resp["kept_at"]}.")
      end
    )
  end

  defp quarantine(mode) do
    with_body(Client.get("/api/memory/quarantine"), mode, fn body ->
      entries = body["quarantined"] || []

      if entries == [] do
        IO.puts("Nothing is quarantined.")
      else
        IO.puts("QUARANTINED MEMORIES (#{length(entries)})")

        Enum.each(entries, fn e ->
          IO.puts("  #{e["name"]}  (#{e["quarantined_at"]} @ #{e["sha"]})")
          IO.puts("      #{e["reason"]}")
        end)
      end
    end)
  end

  defp restore(args, opts, mode) do
    name = one_arg!(args, "arb memory restore <name>", "name")
    body = %{name: name, reanchor: opts[:reanchor] || false}

    with_body(Client.post("/api/memory/quarantine/restore", body), mode, fn resp ->
      IO.puts("Restored #{resp["name"]} as shared memory #{resp["memory"]}.")
      print_verification(resp)
    end)
  end

  defp distill(args, opts, mode) do
    session_id = one_arg!(args, "arb memory distill <session-id>", "session id")

    body =
      Enum.reduce(
        [:max_bytes, :from_turn, :max_candidates, :max_cost_usd],
        %{session_id: session_id},
        fn key, acc ->
          if value = opts[key], do: Map.put(acc, key, value), else: acc
        end
      )

    with_body(Client.post("/api/memory/distill", body), mode, fn resp ->
      candidates = resp["candidates"] || []
      IO.puts("Distilled #{resp["session_id"]}: #{length(candidates)} candidate(s) queued.")

      Enum.each(candidates, fn c ->
        IO.puts("  #{c["id"]}  [#{c["type"]}]  #{c["name"]}")
      end)

      case resp["rejected"] || [] do
        [] -> :ok
        dropped -> IO.puts("  #{length(dropped)} dropped by the validators.")
      end

      print_cost(resp["cost"])
      if candidates != [], do: IO.puts("Review them with `arb memory pending`.")
    end)
  end

  # ---- helpers -----------------------------------------------------------------

  defp with_body({:ok, body}, :json, _printer), do: IO.puts(Jason.encode!(body))
  defp with_body({:ok, body}, _mode, printer), do: printer.(body)
  defp with_body({:error, err}, _mode, _printer), do: Output.die(err)

  defp one_arg!([value], _usage, _what), do: value

  defp one_arg!(_args, usage, what),
    do: Output.die("#{usage} needs exactly one #{what}", "Run `arb memory --help` for usage.")

  defp print_candidate(c) do
    replaces = if c["replaces_shared"], do: "  (replaces shared)", else: ""
    IO.puts("  #{c["id"]}  [#{c["type"]}]  #{c["name"]}#{replaces}")
    if c["description"], do: IO.puts("      #{c["description"]}")

    if c["rejection_reason"] do
      IO.puts("      rejected by #{c["rejected_by"]}: #{c["rejection_reason"]}")
    end
  end

  defp print_verification(%{"status" => status} = v) do
    IO.puts("Verification: #{status}")
    Enum.each(v["reasons"] || [], &IO.puts("  - #{&1}"))
  end

  defp print_verification(_), do: :ok

  defp print_cost(%{"cost_usd" => cost} = c) do
    over = if c["over_budget"], do: "  (OVER BUDGET)", else: ""
    IO.puts("Cost: $#{cost} of a $#{c["max_cost_usd"]} cap#{over}")
  end

  defp print_cost(_), do: :ok
end
