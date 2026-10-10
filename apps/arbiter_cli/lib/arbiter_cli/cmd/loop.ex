defmodule ArbiterCli.Cmd.Loop do
  @moduledoc """
  `arb loop` — the operator-invoked loop-engineering surface.

  ## `arb loop analyze`

  Run the Stage 1 loop-analysis pass (bd-dyfaq3) over a window and print its
  markdown report. The pass reads `worker_runs ⨝ usage_events ⨝
  review_gate_rounds ⨝ issues`, segments failures operational-vs-agent-quality
  by allowlist (corroborating each `failure_reason` against the transcript),
  clusters reviewer findings, and flags difficulty misestimates — then emits a
  report and **writes nothing** but its own cost row. The operator reads it and
  decides where each lesson lands (a skill, the repo's `CLAUDE.md`, or a
  per-task override).

  Usage:

      arb loop analyze [--since 7d | <iso8601>] [--until <iso8601>]
                       [--limit N] [--workspace <id>] [--propose] [--discover]
                       [--json]

  `--since` accepts `7d` / `24h` / `30m` shortcuts or ISO8601 (default: last 7
  days). `--json` prints the raw envelope (markdown + structured summary)
  instead of just the report.

  The report includes a **CI section** (bd-cuu8n3): the first-push CI red
  rate — the share of PR-bearing tasks that needed at least one CI fix_pass —
  by repo, provider/model and difficulty, with counts; and every fix_pass run
  in the window classified deterministically (no model call) as `lint`,
  `flake_rerun`, `test_fix`, `infra` or `unknown`, with the unknown share
  reported. `--json` carries it under `summary.ci`.

  Known undercount: a fix_pass is only dispatched for an *approved* PR blocked
  on red CI, so a push that went red and was fixed during review is not
  counted — the red rate is a lower bound. (`summary.ci.meta.undercount` says
  the same in JSON.)

  A repo whose lint share exceeds `loop.ci.lint_share_threshold` becomes a
  `repo_doc_patch` proposal under `--propose` ("run <check command> before
  push").

  Without `--propose` the pass is read-only, exactly as it has always been.
  `--propose` additionally persists the proposals the report implies into the
  reviewable queue below — nothing is applied, at any evidence level.

  `--discover` (bd-4f6opo, off by default) adds **one model call** over the
  window's reviewer-finding residue and a "Candidate detectors" section: each a
  proposed `@finding_buckets` regex + category that has passed a deterministic
  pre-check (it matches every residue unit the model claimed, and ≥ 3 units
  across ≥ 2 tasks in retained history), with its match counts and citations;
  rejected candidates are counted with the reason. It writes nothing but its
  own `usage_events` row (step `loop_discovery`) and queues nothing, even with
  `--propose`. Without it, `arb loop analyze` makes no model call.

  ## The proposal queue (Stage 2, bd-9j2g3x)

      arb loop pending [--state proposed|hypothesis|applied|rejected|superseded]
                       [--kind <kind>] [--workspace <id>] [--limit N] [--json]
      arb loop diff <id> [--json]
      arb loop apply <id>
      arb loop apply all [--state proposed] [--workspace <ws>] [--limit N] [--json]
      arb loop reject <id> [--reason "..."]

  ## Hand-authoring a repo CLAUDE.md lesson (bd-1cusio)

      arb loop propose repo-doc-patch --repo <repo> --lesson "..."
                       [--category "..."] [--workspace <id>]

  The Stage 1 pass cannot yet attribute a reviewer-finding category to one
  repo — its only automatic repo_doc_patch producer is the CI lint share
  above — so this is the entry point for any other repo lesson: an
  operator who has read a repo-specific lesson names the repo (its
  `repo_paths` key in that workspace) and the lesson text directly. `--lesson`
  must be a single line with no `arbiter:begin`/`arbiter:end` marker. Lands
  `:proposed` immediately (task-scoped, like a difficulty override) — review
  it with `arb loop diff <id>` and apply it like any other proposal.

  ## Operator-started routing canary

      arb loop propose routing --workspace <ws> --difficulty <n>
                       --model-tier <tier> [--thinking <level>]
      arb loop canary status [--workspace <ws>] [--json]

  `propose routing` writes an operator-authored `routing.rules.D<n>` proposal,
  already `:proposed`. With `loop.autonomous_routing_enabled` set on the
  workspace, the next 15-minute canary tick starts a 50/50 canary for it. Set
  `loop.canary_auto_promote` to `false` to have a passing verdict mail the
  coordinator instead of landing the rule — then decide with `arb loop apply
  <id>` / `arb loop reject <id>`. `canary status` prints both arms' current
  metrics and how far the canary is from a verdict. See
  `docs/loop-review.md`.

  A finding below the evidence bar is kept as a `hypothesis` carrying its
  incident refs, so a later window reinforces it in place rather than starting
  its count from zero. Crossing the bar (default: 3 incidents across 2 distinct
  tasks, overridable per workspace under `loop.evidence_bar`) promotes it to
  `proposed` and escalates once. `arb loop pending` shows the live states
  (`hypothesis` + `proposed`) unless `--state` says otherwise.

  Each row is priced as well as counted: the `+120ctx` / `free` column is the
  *recurring* context the proposal would add to every future dispatch if
  applied. A per-task override and a difficulty change are free forever; a
  fleet-wide skill clause is not, and the price is in view before you approve it.

  `apply` calls the same public domain API a human would, so every application
  leaves a normal paper-trail version attributed to the proposal id. Rejection
  is soft: the row persists as `rejected` and keeps accumulating evidence, but
  never re-opens on its own.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  # Pre-existing complexity 15 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["analyze" | tail] ->
          analyze(tail, mode)

        ["propose", "repo-doc-patch" | tail] ->
          propose_repo_doc_patch(tail, mode)

        ["propose", "routing" | tail] ->
          propose_routing(tail, mode)

        ["canary", "status" | tail] ->
          canary_status(tail, mode)

        ["canary" | _] ->
          Output.die("usage: arb loop canary status [--workspace <ws>]")

        ["propose" | _] ->
          Output.die(
            "usage: arb loop propose repo-doc-patch --repo <repo> --lesson \"...\" | " <>
              "arb loop propose routing --workspace <ws> --difficulty <n> --model-tier <tier> " <>
              "[--thinking <level>]"
          )

        ["pending" | tail] ->
          pending(tail, mode)

        ["diff", id | tail] ->
          _ = ArgParser.parse(tail, command: "arb loop diff", switches: [])
          diff(id, mode)

        ["diff" | _] ->
          Output.die("usage: arb loop diff <id>")

        ["apply", "all" | tail] ->
          apply_all(tail, mode)

        ["apply", id | tail] ->
          _ = ArgParser.parse(tail, command: "arb loop apply", switches: [])
          apply_one(id, mode)

        ["apply" | _] ->
          Output.die("usage: arb loop apply <id> | arb loop apply all")

        ["reject", id | tail] ->
          reject(id, tail, mode)

        ["reject" | _] ->
          Output.die("usage: arb loop reject <id> [--reason \"...\"]")

        [] ->
          analyze([], mode)

        [other | _] ->
          Output.die("unknown `arb loop` subcommand: #{other}")
      end
    end
  end

  # The discovery model call is capped server-side at 300s by default; leave
  # headroom for the deterministic pass around it.
  @discover_timeout_ms 360_000

  defp analyze(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop analyze",
        switches: [
          since: :string,
          until: :string,
          limit: :integer,
          workspace: :string,
          propose: :boolean,
          discover: :boolean
        ],
        aliases: [s: :since, l: :limit, w: :workspace]
      )

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))

    params =
      []
      |> maybe_put(:since, Keyword.get(opts, :since))
      |> maybe_put(:until, Keyword.get(opts, :until))
      |> maybe_put(:limit, Keyword.get(opts, :limit))
      |> maybe_put(:workspace_id, ws_id)

    # Both routes are POSTs: the pass records its own `usage_events` row (and
    # `--discover` makes a model call), so neither is a GET (D-C-30).
    # `--propose` is a different verb on a different route, not a flag on the
    # report-only analyze. `--discover` (bd-4f6opo) queues nothing either, so it
    # is a body param on whichever route runs; it makes a model call, so it gets
    # a longer receive timeout.
    route =
      if Keyword.get(opts, :propose, false), do: "/api/loop/propose", else: "/api/loop/analyze"

    result =
      if Keyword.get(opts, :discover, false) do
        Client.post(route, params |> Map.new() |> Map.put(:discover, true),
          receive_timeout: @discover_timeout_ms
        )
      else
        Client.post(route, Map.new(params))
      end

    case result do
      {:ok, %{"markdown" => markdown} = envelope} -> emit(markdown, envelope, mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp propose_repo_doc_patch(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop propose",
        switches: [repo: :string, lesson: :string, category: :string, workspace: :string],
        aliases: [r: :repo, l: :lesson, w: :workspace]
      )

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))

    body =
      %{}
      |> maybe_put_map("repo", Keyword.get(opts, :repo))
      |> maybe_put_map("lesson", Keyword.get(opts, :lesson))
      |> maybe_put_map("category", Keyword.get(opts, :category))
      |> maybe_put_map("workspace_id", ws_id)

    case Client.post("/api/loop/propose/repo_doc_patch", body) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "proposed", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp propose_routing(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop propose",
        switches: [
          workspace: :string,
          difficulty: :string,
          model_tier: :string,
          thinking: :string
        ],
        aliases: [w: :workspace]
      )

    opts = ArgParser.coerce_difficulty(opts)

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))

    body =
      %{}
      |> maybe_put_map("workspace_id", ws_id)
      |> maybe_put_map("difficulty", Keyword.get(opts, :difficulty))
      |> maybe_put_map("model_tier", Keyword.get(opts, :model_tier))
      |> maybe_put_map("thinking", Keyword.get(opts, :thinking))

    case Client.post("/api/loop/propose/routing", body) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "proposed", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp canary_status(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop canary",
        switches: [workspace: :string],
        aliases: [w: :workspace]
      )

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))

    params = maybe_put([], :workspace_id, ws_id)

    case Client.get("/api/loop/canary", params) do
      {:ok, envelope} when mode == :json -> IO.puts(Jason.encode!(envelope))
      {:ok, %{"running" => false, "message" => message}} -> IO.puts(message)
      {:ok, %{"running" => true, "status" => status}} -> IO.puts(format_canary_status(status))
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  @doc false
  def format_canary_status(s) do
    rule = s["rule"] |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    header = [
      "Canary #{s["proposal_id"]} on D#{s["difficulty"]} (#{rule}) — proposal #{s["proposal_state"]}",
      "Started #{s["started_at"]} (#{Float.round(s["age_days"] / 1, 1)}d ago); expires #{s["expires_at"]}",
      "Canary-arm dispatches until a verdict is possible: #{s["dispatches_left"]} " <>
        "(of #{s["min_dispatches"]})",
      "Verdict if judged now: #{s["verdict"]}" <>
        if(s["auto_promote"], do: "", else: " (loop.canary_auto_promote=false: you decide)"),
      ""
    ]

    rows =
      for {label, key} <- [{"canary", "canary"}, {"control", "control"}] do
        a = s[key]

        "  #{String.pad_trailing(label, 8)} dispatches=#{a["dispatches"]} tasks=#{a["tasks"]} " <>
          "reviewed=#{a["reviewed_tasks"]} first-pass=#{fmt_pct(a["first_pass_convergence"])} " <>
          "rounds=#{a["review_rounds"]} cost=$#{a["cost_usd"]} " <>
          "cost/round=#{fmt_money(a["cost_per_round"])}"
      end

    Enum.join(header ++ rows, "\n")
  end

  defp fmt_pct(nil), do: "—"
  defp fmt_pct(f) when is_number(f), do: "#{Float.round(f * 100, 1)}%"

  defp fmt_money(nil), do: "—"
  defp fmt_money(c) when is_number(c), do: "$#{Float.round(c / 1, 4)}"

  defp emit(_markdown, envelope, :json), do: IO.puts(Jason.encode!(envelope))

  defp emit(markdown, envelope, :text) do
    IO.puts(markdown)

    case Map.get(envelope, "proposals") do
      rows when is_list(rows) and rows != [] ->
        IO.puts("\n## Queued proposals (#{length(rows)})\n")
        Enum.each(rows, &IO.puts(pending_line(&1)))
        IO.puts("\nReview with `arb loop pending`; apply with `arb loop apply <id>`.")

      _ ->
        :ok
    end

    case Map.get(envelope, "proposals_dropped") do
      dropped when is_list(dropped) and dropped != [] ->
        IO.puts("\n## Dropped candidates (#{length(dropped)})\n")

        Enum.each(dropped, fn %{"gist" => gist, "reason" => reason} ->
          IO.puts("- #{gist || "(no gist)"}: #{reason}")
        end)

        IO.puts(
          "\nEach was refused by the write path (e.g. an ambiguous install with no default " <>
            "workspace) and was not queued."
        )

      _ ->
        :ok
    end
  end

  # ---- the proposal queue -------------------------------------------------

  defp pending(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop pending",
        switches: [state: :string, kind: :string, workspace: :string, limit: :integer],
        aliases: [l: :limit, w: :workspace]
      )

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))
    state = validate_states(Keyword.get(opts, :state))

    params =
      []
      |> maybe_put(:state, state)
      |> maybe_put(:kind, Keyword.get(opts, :kind))
      |> maybe_put(:workspace_id, ws_id)
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case Client.get("/api/loop/pending", params) do
      {:ok, %{"pending" => rows} = envelope} -> emit_pending(rows, envelope, mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_pending(_rows, envelope, :json), do: IO.puts(Jason.encode!(envelope))

  defp emit_pending([], envelope, :text) do
    bar = Map.get(envelope, "evidence_bar") || %{}

    IO.puts(
      "no queued loop proposals (evidence bar: #{Map.get(bar, "min_incidents")} incidents " <>
        "across #{Map.get(bar, "min_distinct_tasks")} distinct tasks)"
    )
  end

  defp emit_pending(rows, _envelope, :text) do
    Enum.each(rows, &IO.puts(pending_line(&1)))
  end

  defp pending_line(row) do
    [
      String.pad_trailing(to_string(row["id"]), 38),
      String.pad_trailing(state_field(row), 27),
      String.pad_trailing(to_string(row["kind"]), 20),
      String.pad_trailing("#{row["evidence_count"]}i/#{row["distinct_tasks"]}t", 9),
      String.pad_trailing(context_cost(row["context_cost_tokens"]), 9),
      to_string(row["gist"])
    ]
    |> Enum.join(" ")
  end

  # bd-bldypb: a row whose payload can't satisfy its kind's apply
  # preconditions is marked beside the state — the listing problem the
  # payload-less rows caused, without suppressing the evidence they carry.
  defp state_field(row) do
    cond do
      row["kind"] in @operator_only_kinds -> "#{row["state"]} (operator-only)"
      row["needs_authoring"] -> "#{row["state"]} (needs authoring)"
      true -> to_string(row["state"])
    end
  end

  # Amendment D: the recurring per-dispatch price of applying a proposal, shown
  # in the queue itself so a fleet-wide prompt addition can't be approved
  # without its standing cost in view. A per-task override is genuinely free
  # forever, and "free" says that more plainly than "0ctx".
  defp context_cost(tokens) when is_integer(tokens) and tokens > 0, do: "+#{tokens}ctx"
  defp context_cost(_), do: "free"

  defp context_cost_detail(tokens) when is_integer(tokens) and tokens > 0,
    do: "~#{tokens} token(s) added to every dispatch that carries this, for as long as it lives"

  defp context_cost_detail(_), do: "0 tokens (charged once, not to every dispatch)"

  defp diff(id, mode) do
    case Client.get("/api/loop/pending/#{id}") do
      {:ok, %{"pending" => row}} when mode == :json -> IO.puts(Jason.encode!(row))
      {:ok, %{"pending" => row}} -> print_detail(row)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp print_detail(row) do
    IO.puts("#{row["id"]}  #{row["state"]}  #{row["kind"]}  (scope: #{row["scope"]})")
    IO.puts(row["gist"])

    IO.puts(
      "\nevidence: #{row["evidence_count"]} incident(s) across " <>
        "#{row["distinct_tasks"]} distinct task(s)"
    )

    IO.puts("context cost: #{context_cost_detail(row["context_cost_tokens"])}")

    if row["target_metric"], do: IO.puts("target metric: #{row["target_metric"]}")
    if row["baseline"], do: IO.puts("baseline: #{row["baseline"]}")
    if row["inapplicable_reason"], do: IO.puts("\nnot applicable: #{row["inapplicable_reason"]}")
    if row["authoring_gap"], do: IO.puts("\nneeds authoring: #{row["authoring_gap"]}")

    case row["diff"] do
      diff when is_binary(diff) and diff != "" -> IO.puts("\n" <> diff)
      _ -> IO.puts("\n(no diff — this proposal carries a payload, not a patch)")
    end
  end

  defp apply_one(id, mode) do
    case Client.post("/api/loop/pending/#{id}/apply", %{}) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "applied", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  # `apply all` is a convenience over the same per-row endpoint — never a
  # server-side bulk write, so one bad row cannot take the batch with it. It
  # keeps going past a failed row, reports every row (`--json`: one array, a
  # failed row is `{"id", "error"}`), and exits non-zero if any failed.
  defp apply_all(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv,
        command: "arb loop apply",
        switches: [state: :string, workspace: :string, limit: :integer],
        aliases: [l: :limit, w: :workspace]
      )

    ws_id = ArbiterCli.Workspace.selected_id(Keyword.get(opts, :workspace))
    state = validate_states(Keyword.get(opts, :state, "proposed"))

    params =
      [state: state]
      |> maybe_put(:workspace_id, ws_id)
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case Client.get("/api/loop/pending", params) do
      {:ok, %{"pending" => rows}} ->
        {operator_only, rows} = Enum.split_with(rows, &(&1["kind"] in @operator_only_kinds))
        Enum.each(operator_only, &note_operator_only/1)
        apply_batch(rows, mode)

      {:ok, other} ->
        Output.die("unexpected response: #{inspect(other)}")

      {:error, err} ->
        Output.die(err)
    end
  end

  # G18: a `trust_promotion` loosens a subject's guardrails, so the server
  # refuses it here at any authority and the operator applies it with operator
  # proof. Mirrors `Arbiter.Loop.PendingWrite.operator_only_kinds/0`.
  @operator_only_kinds ["trust_promotion"]

  defp note_operator_only(row) do
    IO.puts(
      :stderr,
      "arb: skipped #{row["id"]} (#{row["kind"]}): operator-only — the operator applies it " <>
        "with `arb trust promote #{row["target"] || "<subject>"} --to <tier> --reason \"...\"` " <>
        "(see `arb trust show #{row["target"] || ""}`)"
    )
  end

  defp apply_batch([], :json), do: IO.puts("[]")
  defp apply_batch([], :text), do: IO.puts("nothing to apply")
  defp apply_batch(rows, mode), do: rows |> Enum.map(&apply_in_batch/1) |> report_batch(mode)

  defp apply_in_batch(row) do
    case Client.post("/api/loop/pending/#{row["id"]}/apply", %{}) do
      {:ok, %{"pending" => applied}} ->
        {:ok, applied}

      {:ok, other} ->
        {:error, row["id"], "unexpected response #{inspect(other)}"}

      {:error, err} ->
        {:error, row["id"], error_message(err)}
    end
  end

  defp report_batch(results, :json) do
    results
    |> Enum.map(fn
      {:ok, applied} -> applied
      {:error, id, message} -> %{"id" => id, "error" => message}
    end)
    |> Output.emit_json()

    exit_unless_all_applied(results)
  end

  defp report_batch(results, :text) do
    Enum.each(results, fn
      {:ok, applied} -> emit_decision(applied, "applied", :text)
      {:error, id, message} -> IO.puts(:stderr, "arb: error: #{id} not applied: #{message}")
    end)

    exit_unless_all_applied(results)
  end

  defp exit_unless_all_applied(results) do
    case Enum.count(results, &match?({:error, _, _}, &1)) do
      0 ->
        :ok

      failed ->
        IO.puts(
          :stderr,
          "arb: error: #{failed} of #{length(results)} proposal(s) failed to apply"
        )

        Output.halt(1)
    end
  end

  defp reject(id, argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse(argv, command: "arb loop reject", switches: [reason: :string])

    body = maybe_put_map(%{}, "reason", Keyword.get(opts, :reason))

    case Client.post("/api/loop/pending/#{id}/reject", body) do
      {:ok, %{"pending" => row}} -> emit_decision(row, "rejected", mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_decision(row, _verb, :json), do: IO.puts(Jason.encode!(row))
  defp emit_decision(row, verb, :text), do: IO.puts("#{verb} #{row["id"]}: #{row["gist"]}")

  # Mirrors `Arbiter.Loop.PendingWrite.states/0` (the CLI escript cannot depend
  # on the server app). The server validates too; this refuses a typo before a
  # request is made, so it cannot look like an empty queue, and `apply all`
  # cannot be pointed at a state it never meant.
  @states ~w(proposed hypothesis applied rejected superseded)

  defp validate_states(nil), do: nil

  defp validate_states(raw) when is_binary(raw) do
    names = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    case {names, Enum.reject(names, &(&1 in @states))} do
      {[], _} ->
        Output.die("--state needs at least one of: #{Enum.join(@states, ", ")}")

      {_, []} ->
        Enum.join(names, ",")

      {_, bad} ->
        Output.die(
          "unknown state(s) #{inspect(bad)}; expected one of #{Enum.join(@states, ", ")}"
        )
    end
  end

  defp error_message(%Client.Error{message: message}) when is_binary(message), do: message
  defp error_message(err), do: inspect(err)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, _key, ""), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)
end
