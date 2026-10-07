defmodule ArbiterCli.Cmd.Review do
  @moduledoc """
  `arb review` — code review, for tickets and for PRs the fleet never opened.

      arb review <task-id> [--repo <repo>] [--model <name>] [--json]
      arb review --pr <url|number|owner/repo#N> [--repo <repo>] [--json]
      arb review list [--status s] [--since ts] [--limit n] [--json]
      arb review show <id> [--json]
      arb review transcript <id> [--tail N] [--no-prompt] [--json]
      arb review rounds <task-id> [--limit n] [--json]
      arb review greenlight <id> [--select all|none|0,2,..] [--no-post-verdict] [--json]
      arb review resolve <task-id> --amend "<reasoning>"   (== arb ticket resolve)

  ## Task review (positional `<task-id>`)

  Dispatch a review-only worker against the PR/MR linked to a task
  (`arb worker review <task-id>` is the same call). POSTs to `/api/workers/review`.
  The server transitions the task to `:active`, attaches the
  `Arbiter.Workflows.CodeReview` workflow, **skips** worktree provisioning and
  per-task branch creation, and spawns a Claude subprocess with a review prompt.
  The reviewer reads the PR/MR diff, posts findings + a verdict via the
  configured tracker, and prints `arb done`.

  ## External PR review (`--pr`)

  Review a PR the fleet never opened (a coworker's): no task, no branch.
  Constructs an `mr_ref` through the workspace's MR-provider adapter (the
  github/gitlab merger — NOT the issue tracker) and runs `CodeReview` in
  `:adapter` mode: read the diff, post per-finding inline comments, submit a
  single verdict — all on the PR itself. `--pr` accepts a forge URL, an
  `owner/repo#N` slug, or a bare number (with `--repo` so a number can be
  resolved to owner/repo via the checkout's `origin` remote). Add
  `--report-only` (or `--automation report_only`) to post NOTHING and instead
  read the proposed comments with `arb review show`, then post the ones you
  approve with `arb review greenlight`.

  ## Reading and finishing external reviews

    * `list`       — recent review records, newest first; `MODE` and `GREENLIGHT`
                     say which report-only reviews are awaiting a greenlight.
    * `show`       — one record with its numbered `proposed_comments` (the indices
                     `--select` takes) and its transcript state.
    * `transcript` — the durable corpus of one review (prompt, tools used, transcript).
                     `arb worker log`'s counterpart for a review, which — not being
                     task-linked — has no run to look up. `--transcript <id>` is the
                     older spelling.
    * `rounds`     — a task's ReviewGate rounds, with the gate's outcome and any
                     recorded resolution.
    * `greenlight` — post the approved subset of a report-only review's proposed
                     comments to the PR, and nothing else. `--select` is `all`
                     (default), `none`, or comma-separated zero-based indices.
                     Needs a token that may dispatch, like the review itself.
    * `resolve`    — record your answer to a gate escalation.

  Record ids come from `arb review --pr` output, `arb review list` or the
  `/reviews` page.

  ## Flags

    --pr <url|number>  Review an external PR/MR (no task id needed).
    --repo <repo>      Local checkout. For a task review, the cwd the reviewer
                       runs in. For `--pr`/`greenlight`, used to resolve owner/repo
                       for a bare PR number.
    --workspace <ref>  Workspace name/id (`-w`): whose MR provider `--pr` uses, and
                       which workspace's records `list` shows. Default: the
                       installation's sole/`default` workspace for `--pr`; every
                       workspace for `list`.
    --model <name>     (task review only) one-shot model override
                       (`haiku|sonnet|opus`).
    --force            Dispatch even when review_automation resolves to "off", or
                       when the fleet identity already approved the PR.
    --force-quota      (task review only) bypass the quota gate for this dispatch.
    --automation <m>   Override the resolved review_automation mode for this review
                       (auto | report_only | flag | off).
    --report-only      (`--pr` only) post nothing; report proposed comments.
    --follow-up / --no-follow-up
                       (`--pr` only) adopt the PR into ReviewPatrol after the verdict
                       (default: yes when the workspace runs a ReviewPatrol).
    --scope <diff|repo>
                       (`--pr` only) review depth; default from the workspace's
                       `review_scope` policy.
    --pr-author <login>  (task review only) PR author, matched against
                       review_automation.auto_authors.
    --tracker-context-ref <ref>   Ticket the review should read acceptance criteria
                       from (a coworker's ticket this task does not claim).
    --tracker-context-type <type> Tracker type of --tracker-context-ref (default: the
                       workspace's tracker).
    --status <s>       (`list`) running | completed | failed.
    --since <ts>       (`list`) ISO 8601 lower bound on the review's start.
    --limit <n>        (`list`, `rounds`) at most N rows (`list`: default 20, max 200;
                       `rounds`: the most recent N).
    --select <spec>    (`greenlight`) all | none | 0,2,3.
    --post-verdict / --no-post-verdict
                       (`greenlight`) also submit the recommended verdict (default:
                       yes when at least one comment is approved).
    --tail <n>         (`transcript`) only the last N transcript lines.
    --no-prompt        (`transcript`) omit the (large) review prompt.
    --json             emit JSON instead of human-readable text

  ## What this does NOT do

  Reviews never push, merge, or modify a branch. Adding a `--push` flag
  would defeat the purpose — to dispatch authored work, use `arb dispatch`.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [
    json: :boolean,
    repo: :string,
    model: :string,
    pr: :string,
    workspace: :string,
    transcript: :string,
    tail: :integer,
    prompt: :boolean,
    force: :boolean,
    force_quota: :boolean,
    automation: :string,
    report_only: :boolean,
    follow_up: :boolean,
    scope: :string,
    pr_author: :string,
    tracker_context_ref: :string,
    tracker_context_type: :string,
    status: :string,
    since: :string,
    limit: :integer,
    select: :string,
    post_verdict: :boolean
  ]

  @subcommands ~w(list show transcript rounds greenlight)

  def run(argv) do
    cond do
      Output.help?(argv) ->
        IO.puts(@moduledoc)

      # `arb review resolve` is the spelling the gate-escalation mail names.
      match?(["resolve" | _], argv) ->
        ArbiterCli.Cmd.Resolve.run(tl(argv))

      true ->
        {sub, argv} = split_subcommand(argv)
        {opts, rest, _mode} = ArgParser.parse(argv, command: "arb review", switches: @switches)
        mode = if opts[:json], do: :json, else: :text
        dispatch(sub, opts, rest, mode)
    end
  end

  defp split_subcommand([sub | rest]) when sub in @subcommands, do: {sub, rest}
  defp split_subcommand(argv), do: {nil, argv}

  defp dispatch("list", opts, rest, mode) do
    no_args!(rest, "list")
    run_list(opts, mode)
  end

  defp dispatch("show", _opts, rest, mode), do: run_show(one_arg!(rest, "show", "<id>"), mode)

  defp dispatch("transcript", opts, rest, mode),
    do: run_transcript(Keyword.put(opts, :transcript, one_arg!(rest, "transcript", "<id>")), mode)

  defp dispatch("rounds", opts, rest, mode),
    do: run_rounds(one_arg!(rest, "rounds", "<task-id>"), opts, mode)

  defp dispatch("greenlight", opts, rest, mode),
    do: run_greenlight(one_arg!(rest, "greenlight", "<id>"), opts, mode)

  defp dispatch(nil, opts, rest, mode) do
    cond do
      opts[:transcript] not in [nil, ""] -> run_transcript(opts, mode)
      opts[:pr] not in [nil, ""] -> run_external(opts, mode)
      true -> run_task(opts, rest, mode)
    end
  end

  defp no_args!([], _sub), do: :ok
  defp no_args!(_, sub), do: Output.die("review #{sub} takes no positional arguments")

  defp one_arg!([arg], _sub, _what), do: arg
  defp one_arg!([], sub, what), do: Output.die("review #{sub} requires: #{what}")
  defp one_arg!(_, sub, what), do: Output.die("review #{sub} takes a single argument: #{what}")

  # The workspace `-w`/`--workspace`/ARB_WORKSPACE names, as the server resolves
  # it (id or name). `nil` when none was named.
  defp workspace_ref(opts) do
    case opts[:workspace] || System.get_env("ARB_WORKSPACE") do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  # External / non-arbiter PR review — no task id, keyed on --pr.
  defp run_external(opts, mode) do
    body =
      %{"pr" => opts[:pr]}
      |> maybe_put("repo", opts[:repo])
      |> maybe_put("workspace", workspace_ref(opts))
      |> maybe_put("force", if(opts[:force], do: true))
      |> maybe_put("automation", opts[:automation])
      |> maybe_put("report_only", if(opts[:report_only], do: true))
      |> maybe_put("follow_up", opts[:follow_up])
      |> maybe_put("scope", opts[:scope])
      |> maybe_put("tracker_context_ref", opts[:tracker_context_ref])
      |> maybe_put("tracker_context_type", opts[:tracker_context_type])

    case Client.post("/api/workers/review", body) do
      {:ok, payload} -> emit_external(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp run_task(opts, rest, mode) do
    task_id =
      case rest do
        [id] ->
          id

        [] ->
          Output.die(
            "review requires a task id (e.g. `arb review bd-4b39bf`), `--pr <url|number>`, " <>
              "or a subcommand (list, show, transcript, rounds, greenlight, resolve)"
          )

        _ ->
          Output.die("review takes a single positional argument: <task-id>")
      end

    body =
      %{"task_id" => task_id}
      |> maybe_put("repo", opts[:repo])
      |> maybe_put("model", opts[:model])
      |> maybe_put("force", if(opts[:force], do: true))
      |> maybe_put("force_quota", if(opts[:force_quota], do: true))
      |> maybe_put("automation", opts[:automation])
      |> maybe_put("pr_author", opts[:pr_author])
      |> maybe_put("tracker_context_ref", opts[:tracker_context_ref])
      |> maybe_put("tracker_context_type", opts[:tracker_context_type])

    case Client.post("/api/workers/review", body) do
      {:ok, payload} -> emit(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # Read-back path: no dispatch, just this review's persisted corpus.
  defp run_transcript(opts, mode) do
    query =
      []
      |> then(fn q -> if opts[:tail], do: [{"tail", opts[:tail]} | q], else: q end)
      |> then(fn q ->
        if opts[:prompt] == false, do: [{"include_prompt", "false"} | q], else: q
      end)

    path =
      "/api/external_reviews/#{opts[:transcript]}/transcript" <>
        if query == [], do: "", else: "?" <> URI.encode_query(query)

    case Client.get(path) do
      {:ok, payload} -> emit_transcript(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_transcript(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_transcript(payload, :text) do
    data = payload["data"] || payload

    IO.puts("Review #{data["record_id"]} — #{data["pr_ref"]} (#{data["status"]})")
    IO.puts("  Model:    #{data["model"] || "—"}")
    IO.puts("  Path:     #{data["path"]}")

    if data["exists"] || data["prompt_exists"] do
      emit_transcript_prompt(data["prompt"])
      emit_transcript_tools(data)
      emit_transcript_lines(data)
    else
      IO.puts("  (no transcript captured for this review)")
    end
  end

  defp emit_transcript_prompt(nil), do: :ok

  defp emit_transcript_prompt(prompt) do
    IO.puts("\n--- prompt ---")
    IO.puts(prompt)
  end

  defp emit_transcript_tools(data) do
    tools = data["tools_used"] || []

    if tools != [] do
      summary = Enum.map_join(tools, ", ", &"#{&1["name"]} ×#{&1["count"]}")
      IO.puts("\n--- tools (#{data["tool_use_count"]}) ---")
      IO.puts(summary)

      for tool_use <- data["tool_uses"] || [] do
        IO.puts("  #{tool_use["name"]} #{Jason.encode!(tool_use["input"] || %{})}")

        case tool_use["result"] do
          r when is_binary(r) and r != "" -> IO.puts("    → #{first_line(r)}")
          _ -> :ok
        end
      end
    end
  end

  defp emit_transcript_lines(data) do
    lines = data["lines"] || []

    if lines != [] do
      shown = if data["truncated"], do: " (last #{length(lines)})", else: ""
      IO.puts("\n--- transcript: #{data["line_count"]} lines#{shown} ---")
      Enum.each(lines, &IO.puts/1)
    end
  end

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  # ---- list / show -----------------------------------------------------------

  defp run_list(opts, mode) do
    params =
      []
      |> put_param("workspace", workspace_ref(opts))
      |> put_param("status", opts[:status])
      |> put_param("since", opts[:since])
      |> put_param("limit", opts[:limit])

    case Client.get("/api/external_reviews", params) do
      {:ok, payload} -> emit_list(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_list(payload, :text) do
    case payload["data"] || [] do
      [] ->
        IO.puts("(no external reviews)")

      records ->
        IO.puts(
          String.pad_trailing("ID", 38) <>
            String.pad_trailing("STATUS", 11) <>
            String.pad_trailing("MODE", 13) <>
            String.pad_trailing("GREENLIGHT", 12) <>
            String.pad_trailing("VERDICT", 17) <> "PR"
        )

        Enum.each(records, &IO.puts(list_line(&1)))
    end
  end

  defp list_line(r) do
    pending =
      if r["greenlight_status"] == "pending", do: " (#{r["proposed_count"]} proposed)", else: ""

    String.pad_trailing(to_string(r["id"]), 38) <>
      String.pad_trailing(dash(r["status"]), 11) <>
      String.pad_trailing(dash(r["mode"]), 13) <>
      String.pad_trailing(dash(r["greenlight_status"]), 12) <>
      String.pad_trailing(dash(r["verdict"]), 17) <> to_string(r["pr_ref"]) <> pending
  end

  defp run_show(id, mode) do
    case Client.get("/api/external_reviews/#{URI.encode(id, &URI.char_unreserved?/1)}") do
      {:ok, payload} -> emit_show(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_show(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_show(payload, :text) do
    r = payload["data"] || payload

    IO.puts("Review #{r["id"]} — #{r["pr_ref"]} (#{r["status"]})")
    IO.puts("  Mode:       #{dash(r["mode"])}  greenlight: #{dash(r["greenlight_status"])}")
    IO.puts("  Verdict:    #{dash(r["verdict"])}  (#{r["finding_count"] || 0} finding(s))")
    IO.puts("  Model:      #{dash(r["model"])}")

    case r["link"] do
      link when is_binary(link) and link != "" -> IO.puts("  Link:       #{link}")
      _ -> :ok
    end

    case r["failure_reason"] do
      reason when is_binary(reason) and reason != "" ->
        IO.puts("  Failed:     #{r["failure_stage"]}: #{reason}")

      _ ->
        :ok
    end

    IO.puts(
      "  Transcript: #{if r["transcript_exists"], do: "#{r["transcript_line_count"]} lines", else: "none captured"}"
    )

    emit_proposed(r["proposed_comments"] || [])
  end

  defp emit_proposed([]), do: :ok

  defp emit_proposed(comments) do
    IO.puts("\nProposed comments (pass the index to `arb review greenlight --select`):")

    comments
    |> Enum.with_index()
    |> Enum.each(fn {c, i} ->
      diff =
        case c["in_diff"] do
          false -> " [out of diff: will be skipped]"
          _ -> ""
        end

      IO.puts("  [#{i}] #{c["file"]}:#{c["line"]} #{c["severity"]}#{diff}")
      IO.puts("      #{first_line(to_string(c["body"] || c["message"] || ""))}")
    end)
  end

  # ---- rounds ----------------------------------------------------------------

  defp run_rounds(task_id, opts, mode) do
    params = put_param([task_id: task_id], "limit", opts[:limit])

    case Client.get("/api/review_gate_rounds", params) do
      {:ok, payload} -> emit_rounds(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_rounds(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_rounds(payload, :text) do
    rounds = payload["data"] || []

    IO.puts(
      "#{payload["count"] || length(rounds)} of #{payload["total_count"] || length(rounds)} round(s) — outcome: #{dash(payload["outcome"])}"
    )

    for r <- rounds do
      IO.puts(
        "  fix#{r["fix_round_attempt"] || 0} r#{r["round"]} #{r["role"]} " <>
          "#{dash(r["verdict"])} #{r["finding_count"] || 0} finding(s) " <>
          "#{dash(r["reviewer_provider"])}/#{dash(r["reviewer_model"])}"
      )
    end

    for res <- payload["resolutions"] || [] do
      IO.puts(
        "  resolved: #{res["decision"]} (#{res["gate"]}) — #{first_line(res["reasoning"] || "")}"
      )
    end
  end

  # ---- greenlight ------------------------------------------------------------

  defp run_greenlight(id, opts, mode) do
    body =
      %{}
      |> maybe_put("select", parse_select!(opts[:select]))
      |> maybe_put("post_verdict", opts[:post_verdict])
      |> maybe_put("repo", opts[:repo])

    case Client.post(
           "/api/external_reviews/#{URI.encode(id, &URI.char_unreserved?/1)}/greenlight",
           body
         ) do
      {:ok, payload} -> emit_greenlight(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # nil → omit (the server posts every comment); "none" → [] (approve nothing).
  defp parse_select!(nil), do: nil
  defp parse_select!("all"), do: "all"
  defp parse_select!(none) when none in ["none", ""], do: []

  defp parse_select!(spec) do
    indices = spec |> String.split(",", trim: true) |> Enum.map(&Integer.parse(String.trim(&1)))

    if indices != [] and Enum.all?(indices, &match?({n, ""} when n >= 0, &1)) do
      Enum.map(indices, &elem(&1, 0))
    else
      Output.die("invalid --select #{inspect(spec)} (use all, none, or indices like 0,2)")
    end
  end

  defp emit_greenlight(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_greenlight(payload, :text) do
    r = payload["data"] || payload

    IO.puts("Greenlit #{r["mr_ref"]}:")
    IO.puts("  Posted:   #{r["posted"]} of #{r["proposed"]} proposed comment(s)")

    if (r["skipped"] || 0) > 0,
      do: IO.puts("  Skipped:  #{r["skipped"]} (out of diff or failed to post)")

    IO.puts(
      "  Verdict:  #{if r["verdict_posted"], do: "submitted (#{r["verdict"]})", else: "not submitted"}"
    )

    case r["link"] do
      link when is_binary(link) and link != "" -> IO.puts("  Link:     #{link}")
      _ -> :ok
    end
  end

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: params ++ [{key, value}]

  defp dash(nil), do: "—"
  defp dash(v), do: to_string(v)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_external(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_external(payload, :text) do
    data = payload["data"] || payload

    IO.puts("External review dispatched:")
    IO.puts("  PR:       #{data["pr"]}")
    IO.puts("  Ref:      #{data["mr_ref"]}")
    IO.puts("  Provider: #{data["strategy"]}")

    case data["link"] do
      link when is_binary(link) and link != "" -> IO.puts("  Link:     #{link}")
      _ -> :ok
    end

    IO.puts("  Findings + a verdict will be posted to the PR.")
  end

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Review dispatched:")
    IO.puts("  Ticket:    #{task["id"]} — #{task["title"]}")
    IO.puts("  State:    #{task["state"]}")
    IO.puts("  Worker:  #{worker["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["claude_started"] do
      true -> IO.puts("  Claude:   started")
      _ -> :ok
    end
  end
end
