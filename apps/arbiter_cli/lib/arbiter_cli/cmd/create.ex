defmodule ArbiterCli.Cmd.Create do
  @moduledoc """
  `arb create <title> [--description ...] [--acceptance ... | --acceptance-file PATH]
                       [--notes ...] [--qa-notes ...] [--deployment-notes ...]
                       [--priority N] [--difficulty N] [--type T]
                       [--deps id1,id2] [--labels a,b]
                       [--tracker-ref REF] [--tracker-type T]
                       [--tracker-context-type T] [--tracker-context-ref REF]
                       [--no-tracker] [--target-branch NAME] [--repo owner/name]
                       [--parent <parent-id>] [--auto-close] [--verify-after-deploy]
                       [--require-provider P | --exclude-provider P] [--permission P]
                       [--force] [--ticket-only] [--json]`

  Creates a new issue in the resolved workspace (see `ArbiterCli.Workspace`).

  `--acceptance TEXT` sets the acceptance criteria at create time, so a
  bug/feature can be promoted to Ready straight away. `--acceptance-file PATH`
  reads the (usually multi-line) criteria from a file instead (`-` for stdin);
  pass one or the other. Unknown flags are rejected with a non-zero exit rather
  than silently dropped.

  `--notes` / `--qa-notes` / `--deployment-notes` seed those fields at create
  time (P-08). `--tracker-type T` sets which tracker the ticket is linked to
  (`github`, `jira`, `none`, …); `--tracker-context-type` / `--tracker-context-ref`
  set the read-only parent-ticket context a child carries (#1973). Every flag
  maps onto a field MCP `ticket_create` / `POST /api/issues` accept.

  Intentionally **not** exposed (internal engagement state or server-derived):
  `source_pr` and the ReviewPatrol / PRPatrol seed fields (`review_only`,
  `last_reviewed_sha`, `last_seen_comment_id`, `review_automation`,
  `posted_findings`, `last_verdict`, `last_verdict_sha`), `skills`, and
  `tracker_child_policy` (a workspace config). `workspace_id` comes from
  `-w` / `ARB_WORKSPACE`, not a flag.

  ## --difficulty N (0..5 / D0..D5)

  Sets how hard the task is. Orthogonal to `--priority`: priority answers
  "how urgent?"; difficulty answers "how hard?" and drives the model +
  thinking budget routed to workers that work the task. Classify by the
  MAX over: scope (files/modules touched), design uncertainty, reasoning
  depth (mechanical vs concurrency/correctness), blast radius, breadth of
  context required.

      D0 Trivial  — single-file, fully specified, no judgment
                    (typo, rename, config bump, doc edit).
      D1 Simple   — localized, clear approach, light reasoning;
                    follows an existing pattern.
      D2 Moderate — multi-file or some design choice; the common
                    feature case. **Default when unspecified.**
      D3 Hard     — cross-cutting, non-obvious design,
                    concurrency/state/edge-case correctness,
                    several components.
      D4 Extreme  — novel architecture, deep ambiguity,
                    correctness-critical; may warrant exploration
                    or multiple passes.
      D5 Flagship — a deliberate escalation, never an ordinary rating.
                    Work judged worth a full quota window on the
                    flagship model. Reach for it only when D4's
                    premium model at max effort has already failed
                    or is plainly inadequate — "harder than D4" is
                    not a reason. Set by the operator, by hand.

  The coordinator / filing session sets `--difficulty` at create time with a
  one-line justification in the task's description. Routing maps the value
  to abstract `{model_tier, thinking}` (see `Arbiter.Agents.Routing.ByDifficulty`).

  ## --type T (bd-9s9dqz)

  One of `task | research | bug | feature | epic | chore | decision`
  (default `feature`). `bug` / `feature` / `chore` are the code types: the
  worker commits, a PR is opened, ReviewGate engages. `research` and `task`
  are the two no-PR types — no worktree, commit gate, ReviewGate or merge —
  and NEITHER may be used for code work:

      research — an investigation; the worker must write its findings to
                 `notes` before it can complete.
      task     — a plain operational action (a restart, a config flip);
                 completes when the worker reports it done, with a short
                 outcome note. No findings required.

  ## --repo owner/name — required, but usually defaulted (bd-9dwbvt)

  Every issue now carries a repo from the moment it is created. `--repo`
  names one of the workspace's configured `repo_paths` keys; when you omit
  it, the server resolves one for you:

      explicit --repo  →  the workspace's only repo  →  its `default_repo`

  So in a single-repo workspace, or a multi-repo one with a `default_repo`
  set, you never have to pass it. In a multi-repo workspace with no
  `default_repo`, creation is **refused** with an error listing the
  configured repo keys — pass one of them, or set `default_repo` on the
  workspace (`arb config set default_repo <key> [--workspace W]`). A `--repo` that
  is not a configured key is rejected outright rather than persisted for
  dispatch to fail on later.

  An explicit `arb dispatch <id> <repo>` still overrides the issue's repo for
  that one run.

  `--parent <parent-id>` attaches the new issue as a child of an existing parent
  task in the same call, by adding a `parent_of` dependency edge
  (`<parent-id> parent_of <new-id>`). The parent then rolls up child progress
  and can auto-close. The server checks the parent exists and shares the
  workspace *before* it creates anything, so a bad parent files nothing.

  If that parent is linked to a tracker ticket, the child does **not** mint its
  own by default (#1973): it stays local with the parent's ticket as read-only
  context (`tracker_context_ref`), so its branch and PR title still carry the
  parent's key. The workspace's `tracker.child_policy` governs this
  (`context_only` default, `inherit_parent`, `mint`).

  When the workspace has a tracker configured (`config["tracker"]["type"] !=
  none`), the server **also creates a corresponding upstream issue** and
  writes the returned ref back into `tracker_ref`. To opt out of that:

    * `--tracker-ref REF` — bind the new task to an *existing* upstream
      issue (skip outbound create). The ref is passed through to the create
      action as `tracker_ref`; the server's after-transaction hook sees the
      ref is already set and skips the API call.
    * `--no-tracker` / `--local-only` — create a purely local task even on a
      tracker-configured workspace. Forwards `skip_upstream_create=true` as
      the action argument.
    * `--ticket-only` / `--no-task` / `--unclaimed` — create ONLY the upstream
      tracker ticket, with NO local task. The ticket sits unclaimed on the
      shared tracker; anyone can pick it up via `arb claim <ref>`. The workspace
      must have a tracker configured. Mutually exclusive with `--no-tracker` /
      `--local-only` (opposite intent).
      Honored: `--title`, `--description`, `--priority`, `--type`.
      Not honored (warning emitted): `--difficulty`, `--deps`, `--parent`,
      `--tracker-ref`, `--tracker-type`, `--tracker-context-*`, `--acceptance[-file]`,
      `--notes`, `--qa-notes`, `--deployment-notes`, `--target-branch`, `--repo`,
      `--labels`, `--assignee` (deprecated — bd-1ozks5).

  `--deps id1,id2` creates a `blocks` dependency for each listed issue (each
  becomes `<dep_id> blocks <new_id>`), in the same call as the create.

  ### Edges are the server's job (P-14, bd-apj0gq)

  `--deps` and `--parent` ride along in the `POST /api/issues` body: the server
  (`Arbiter.Tasks.Create`) validates every endpoint — it must exist and share the
  new ticket's workspace — before creating anything, then writes the issue and
  its edges. An unknown or cross-workspace endpoint therefore refuses the whole
  create with nothing filed. Only a race (an endpoint deleted between the check
  and the write) can leave a ticket without an edge, and then — like a failed
  tracker mirror — the ticket exists: arb exits non-zero, and with `--json` it
  still prints `{"id": "<created id>", "created": true, "error": {...}}` so a
  script can recover the id rather than file the ticket again.

  ## --require-provider / --exclude-provider (bd-13pqcp)

  Constrain where the ticket's implementer may run: `--require-provider claude`
  (only that provider) or `--exclude-provider agy` (anything but). Both repeat
  and take comma lists; providers are adapter types (`claude`, `gemini`,
  `codex`), and `agy` means `gemini`. A ticket carries one of the two, never
  both. Honoured by every dispatch path (Autopilot, routing, failover, resume,
  fix and conflict passes): when no allowed provider has capacity the ticket is
  held (`held — provider constraint (...)`) and never falls back to an excluded
  one. The reviewer is not constrained. Coordinator/operator only — a worker
  token is refused.

  `--labels` is accepted for interface parity with `bd` but the current Issue
  resource has no `labels` field; the value is reported back in a warning
  unless `--json` is set. The `labels` field is not yet part of the Issue resource.

  `--assignee` is deprecated (bd-1ozks5): Arbiter is a local single-user app
  and no longer tracks an assignee locally, so the flag is accepted and
  ignored with a stderr warning (unless `--json` is set) rather than
  rejected outright — for one release, so an existing script that still
  passes it doesn't break.
  """

  alias ArbiterCli.{
    AcceptanceFlags,
    ArgParser,
    Client,
    Output,
    PermissionFlags,
    ProviderConstraintFlags,
    Workspace
  }

  @switches [
    description: :string,
    notes: :string,
    qa_notes: :string,
    deployment_notes: :string,
    priority: :integer,
    difficulty: :string,
    type: :string,
    deps: :string,
    labels: :string,
    assignee: :string,
    tracker_ref: :string,
    tracker_type: :string,
    tracker_context_type: :string,
    tracker_context_ref: :string,
    target_branch: :string,
    repo: :string,
    no_tracker: :boolean,
    local_only: :boolean,
    ticket_only: :boolean,
    no_task: :boolean,
    unclaimed: :boolean,
    parent: :string,
    auto_close: :boolean,
    verify_after_deploy: :boolean,
    force: :boolean,
    json: :boolean
  ]

  # bd-13pqcp: `--require-provider` / `--exclude-provider` (repeatable).
  @all_switches @switches ++
                  AcceptanceFlags.switches() ++
                  ProviderConstraintFlags.switches() ++ PermissionFlags.switches()

  @doc "Every switch `arb ticket create` takes (read by the field-exposure guard test)."
  @spec switches() :: keyword()
  def switches, do: @all_switches

  # Pre-existing complexity 12 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv, command: "arb ticket create", strict: @all_switches)

      opts = ArgParser.coerce_difficulty(opts)

      title =
        case rest do
          [t] -> t
          [] -> Output.die("create requires a title argument")
          many -> Enum.join(many, " ")
        end

      ticket_only? =
        opts[:ticket_only] == true or opts[:no_task] == true or opts[:unclaimed] == true

      skip_upstream? = opts[:no_tracker] == true or opts[:local_only] == true

      if ticket_only? and skip_upstream? do
        Output.die(
          "--ticket-only and --no-tracker/--local-only are mutually exclusive: " <>
            "--ticket-only creates ONLY the tracker ticket, while --no-tracker skips the tracker entirely"
        )
      end

      if ticket_only? do
        run_ticket_only(opts, title, mode)
      else
        run_task_create(opts, rest, title, skip_upstream?, mode)
      end
    end
  end

  defp run_ticket_only(opts, title, mode) do
    workspace_id = Workspace.id_or_halt()

    ignored =
      [
        {"--difficulty", opts[:difficulty]},
        {"--require-provider", opts[:require_provider]},
        {"--exclude-provider", opts[:exclude_provider]},
        {"--permission", opts[:permission]},
        {"--deps", opts[:deps]},
        {"--parent", opts[:parent]},
        {"--tracker-ref", opts[:tracker_ref]},
        {"--tracker-type", opts[:tracker_type]},
        {"--tracker-context-type", opts[:tracker_context_type]},
        {"--tracker-context-ref", opts[:tracker_context_ref]},
        {"--acceptance", opts[:acceptance]},
        {"--acceptance-file", opts[:acceptance_file]},
        {"--notes", opts[:notes]},
        {"--qa-notes", opts[:qa_notes]},
        {"--deployment-notes", opts[:deployment_notes]},
        {"--target-branch", opts[:target_branch]},
        {"--repo", opts[:repo]},
        {"--labels", opts[:labels]}
      ]
      |> Enum.filter(fn {_flag, val} -> not is_nil(val) end)
      |> Enum.map(fn {flag, _val} -> flag end)

    if ignored != [] and mode == :text do
      IO.puts(
        :stderr,
        "arb: warning: --ticket-only ignores #{Enum.join(ignored, ", ")} (no local task is created)."
      )
    end

    warn_deprecated_assignee(opts[:assignee], mode)

    payload =
      %{"title" => title}
      |> maybe_put("description", opts[:description])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("issue_type", opts[:type])

    ticket =
      case Client.post("/api/workspaces/#{workspace_id}/tracker/tickets", payload) do
        {:ok, body} -> body
        {:error, err} -> Output.die(err)
      end

    Output.emit_ticket(ticket, mode)
  end

  defp run_task_create(opts, _rest, title, skip_upstream?, mode) do
    # Refuse contradictory provider flags before any request.
    constraint = ProviderConstraintFlags.payload(opts)
    acceptance = AcceptanceFlags.resolve!(opts)
    workspace_id = Workspace.id_or_halt()
    force? = opts[:force] == true

    payload =
      %{"title" => title, "workspace_id" => workspace_id}
      |> maybe_put("description", opts[:description])
      |> maybe_put("acceptance", acceptance)
      |> maybe_put("notes", opts[:notes])
      |> maybe_put("qa_notes", opts[:qa_notes])
      |> maybe_put("deployment_notes", opts[:deployment_notes])
      |> maybe_put("priority", opts[:priority])
      |> maybe_put("difficulty", opts[:difficulty])
      |> maybe_put("issue_type", opts[:type])
      |> maybe_put("tracker_ref", opts[:tracker_ref])
      |> maybe_put("tracker_type", opts[:tracker_type])
      |> maybe_put("tracker_context_type", opts[:tracker_context_type])
      |> maybe_put("tracker_context_ref", opts[:tracker_context_ref])
      |> maybe_put("target_branch", opts[:target_branch])
      |> maybe_put("repo", opts[:repo])
      # P-14: the server creates the `parent_of` edge (and defaults a child of a
      # tracker-linked parent to context-only), and the `blocks` edges for
      # `--deps`, in the same call — the CLI no longer orchestrates edges.
      |> maybe_put("parent_id", opts[:parent])
      |> maybe_put_deps(opts[:deps])
      |> maybe_put_flag("auto_close", opts[:auto_close] == true)
      |> maybe_put_flag("verify_after_deploy", opts[:verify_after_deploy] == true)
      |> maybe_put_flag("skip_upstream_create", skip_upstream?)
      |> maybe_put_flag("force", force?)
      |> Map.merge(constraint)
      |> Map.merge(PermissionFlags.create_payload(opts))

    if opts[:labels] && mode == :text do
      IO.puts(
        :stderr,
        "arb: warning: --labels is accepted for interface parity but the ticket resource has no labels field (ignored)."
      )
    end

    warn_deprecated_assignee(opts[:assignee], mode)

    issue =
      case Client.post("/api/issues", payload) do
        {:ok, body} -> body
        {:error, err} -> die_create(err, mode)
      end

    print_acceptance_warnings(issue, mode)
    Output.emit_issue(issue, mode)
  end

  # The server answers 502 (tracker mirror failed) or 422 (an edge failed) with
  # the ticket already created: `error.details.task_id` names it. A script
  # reading `--json` still needs that id, so print it before dying — the id is
  # in the message text too, for `text` mode.
  @spec die_create(Client.Error.t(), :json | :text) :: no_return()
  defp die_create(%Client.Error{body: %{"details" => %{"task_id" => id}} = body} = err, :json)
       when is_binary(id) do
    IO.puts(
      Jason.encode!(%{
        "id" => id,
        "created" => true,
        "error" => Map.take(body, ["type", "message", "details"])
      })
    )

    Output.die(err)
  end

  defp die_create(err, _mode), do: Output.die(err)

  defp maybe_put_deps(payload, nil), do: payload

  defp maybe_put_deps(payload, raw) do
    case raw
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> payload
      ids -> Map.put(payload, "deps", ids)
    end
  end

  # bd-7mbrlg: non-blocking heads-up — the task was created either way, but
  # `ticket_promote` / `arb ticket promote` will later refuse it without ACs
  # or an explicit waiver.
  defp print_acceptance_warnings(issue, :text) do
    for warning <- issue["warnings"] || [] do
      IO.puts(:stderr, "arb: warning: #{warning}")
    end
  end

  defp print_acceptance_warnings(_issue, _mode), do: :ok

  # bd-1ozks5: the local assignee field is gone — accept and ignore
  # `--assignee` for one release rather than breaking an existing script.
  defp warn_deprecated_assignee(nil, _mode), do: :ok

  defp warn_deprecated_assignee(_value, :text) do
    IO.puts(
      :stderr,
      "arb: warning: --assignee is deprecated and ignored — Arbiter is a local " <>
        "single-user app and no longer tracks an assignee locally (bd-1ozks5)."
    )
  end

  defp warn_deprecated_assignee(_value, _mode), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_flag(map, _key, false), do: map
  defp maybe_put_flag(map, key, true), do: Map.put(map, key, true)
end
