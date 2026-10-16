defmodule ArbiterCli.Cmd.Claim do
  @moduledoc """
  `arb claim <ref> [--force] [--difficulty N] [--priority N] [--type T]
  [--repo <repo>] [--json]` — create a task
  linked to a tracker issue assigned to the workspace user.

  Bulk: `arb ticket claim --epic <tracker-epic-id>` or `--query <tracker search>`
  (instead of `<ref>`) lists every matching story, flagging those already
  claimed, and stops — a dry-run preview. Add `--yes` to claim the rest with the
  same `--repo` / `--difficulty` / `--force`. Already-claimed stories are
  reported `existing`, never duplicated, so re-running is safe.

  POSTs to `/api/workspaces/:workspace_id/claim`. The server dispatches
  through the workspace's configured tracker adapter — GitHub, Jira,
  Shortcut, etc. — so `<ref>` is whatever that tracker uses: a GitHub issue
  number (`arb claim 43`), a Jira key (`arb claim AX-1234`), a Shortcut story
  id, and so on. The adapter fetches the issue, verifies it's assigned to the
  workspace's authenticated user (the adapter-defined claim signal), and
  either creates a new task or returns the existing one if a task already
  references that issue.

  Flags:
    --assign       Also take ownership of the tracker issue. Without it the
                   tracker owner is never changed; the result reports
                   owner_changed.
    --force        Skip the assignment-as-claim check. Use only when you
                   *know* you want a task for an issue you don't own (e.g.
                   to track someone else's work).
    --difficulty N Task difficulty (0..5): D0 trivial · D1 easy · D2 medium ·
                   D3 hard · D4 extreme · D5 flagship (a deliberate
                   escalation for work worth a full quota window — not
                   simply "harder than D4"). Drives model tier and thinking
                   budget routed to workers. **Default when unspecified**:
                   the task is created with no difficulty set; routing
                   treats an unset difficulty as D2 at dispatch time.
    --priority N   Task priority (0..4, P0 highest). Overrides the priority the
                   tracker adapter derives (GitHub `priority: N` label;
                   Shortcut "Priority" custom field Highest/High/Medium/Low →
                   0/1/2/3). Unset keeps the derived value, else P2.
    --type T       Issue type (bug, feature, chore, ...). Overrides the type
                   the adapter derives (GitHub labels; Shortcut story_type).
    --repo <repo>  Repo the claimed task belongs to, as a configured
                   `repo_paths` key. Persisted on the task and also printed
                   as a tip for a later `arb dispatch`. Usually unnecessary
                   (bd-9dwbvt): the claim fills it in from the workspace's
                   only repo, else its `default_repo`. A multi-repo
                   workspace with no `default_repo` REFUSES the claim until
                   you pass one of its configured keys.
    --epic <id>    Bulk: claim every story in this tracker epic (Shortcut).
    --query <q>    Bulk: claim every story matching this tracker search.
    --yes          Bulk: actually claim; without it the run is a preview.
    --json         Emit JSON instead of human-readable text.
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  @switches [
    force: :boolean,
    assign: :boolean,
    difficulty: :string,
    priority: :integer,
    type: :string,
    repo: :string,
    epic: :string,
    query: :string,
    yes: :boolean,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket claim", switches: @switches)

      opts = ArgParser.coerce_difficulty(opts)
      mode = if opts[:json], do: :json, else: :text

      if opts[:epic] || opts[:query],
        do: bulk(opts, rest, mode),
        else: single(opts, rest, mode)
    end
  end

  defp single(opts, rest, mode) do
    ref =
      case rest do
        [r] ->
          r

        [] ->
          Output.die(
            "claim requires a tracker ref (e.g. `arb claim 43` for GitHub, `arb claim AX-1234` for Jira)"
          )

        _ ->
          Output.die("claim takes a single positional argument: <ref>")
      end

    workspace_id = Workspace.id_or_halt()

    body =
      %{"ref" => ref}
      |> maybe_put("force", opts[:force])
      |> maybe_put("assign", opts[:assign])
      |> maybe_put("difficulty", opts[:difficulty])
      |> maybe_put("repo", opts[:repo])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("issue_type", opts[:type])

    case Client.post("/api/workspaces/#{workspace_id}/claim", body) do
      {:ok, payload} -> emit(payload, opts[:repo], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp bulk(opts, rest, mode) do
    if rest != [] or (opts[:epic] && opts[:query]) do
      Output.die("pass exactly one of <ref>, --epic or --query")
    end

    workspace_id = Workspace.id_or_halt()

    body =
      %{}
      |> maybe_put("epic", opts[:epic])
      |> maybe_put("query", opts[:query])
      |> maybe_put("yes", opts[:yes])
      |> maybe_put("force", opts[:force])
      |> maybe_put("difficulty", opts[:difficulty])
      |> maybe_put("repo", opts[:repo])

    case Client.post("/api/workspaces/#{workspace_id}/claim", body) do
      {:ok, payload} -> emit_bulk(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_bulk(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_bulk(%{"applied" => applied, "data" => rows}, :text) do
    IO.puts(
      if applied,
        do: "Bulk claim — #{length(rows)} stories:",
        else: "Preview — #{length(rows)} stories (nothing claimed):"
    )

    Enum.each(rows, &emit_bulk_row/1)

    counts =
      rows
      |> Enum.frequencies_by(& &1["status"])
      |> Enum.map_join(", ", fn {k, n} -> "#{n} #{k}" end)

    IO.puts("Summary: #{if counts == "", do: "no matches", else: counts}")

    unless applied, do: IO.puts("Re-run with --yes to claim the unclaimed stories.")
  end

  defp emit_bulk(payload, :text), do: IO.puts(Jason.encode!(payload))

  defp emit_bulk_row(row) do
    detail = row["reason"] || row["task_id"] || ""
    suffix = if detail != "", do: " (#{detail})", else: ""

    IO.puts(
      "  #{String.pad_trailing(row["ref"] || "", 10)} #{String.pad_trailing(row["status"] || "", 13)} #{row["title"]}#{suffix}"
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, _repo, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, repo, :text) do
    task = payload["task"] || %{}

    headline =
      case payload["status"] do
        "created" -> "Claimed #{task["id"]} (new task created)"
        "existing" -> "Already claimed: #{task["id"]}"
        other -> "Claim result: #{other} — #{task["id"]}"
      end

    IO.puts(headline)
    IO.puts("  title:        #{task["title"]}")
    IO.puts("  state:        #{task["state"]}")
    IO.puts("  tracker:      #{task["tracker_type"]}:#{task["tracker_ref"]}")

    if repo do
      IO.puts("")
      IO.puts("Tip: `arb dispatch #{task["id"]} #{repo}` to start work on this task.")
    end
  end
end
