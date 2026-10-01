defmodule ArbiterCli.Cmd.Prime do
  @moduledoc """
  `arb prime` — dump everything a fresh Claude Code session needs to play
  the coordinator role.

  Output (in order):

    0. **Scheduler** — the drain state (`GET /api/scheduler/status`): running,
       paused-and-draining (with what is still in flight), or
       paused-and-quiescent (the only safe restart point). Always shown when
       the server answers, because a pause alone does not mean idle.
    1. **Global Coordinator Inbox** — up to 5 most recent unread messages
       addressed to the coordinator, not scoped to any single workspace.
       Omitted entirely when there are none.
    2. **Per-workspace blocks** (one per configured workspace, in server order):
       a. Workspace header — name, prefix, id, tracker, security posture.
       b. Standing Orders — the domain's operating disciplines, sourced from
          `config.standing_orders`. Omitted when empty.
       c. Per-repo Standing Orders — one section per repo carrying orders in
          `config.repo_paths.<repo>.standing_orders`. Omitted per repo when
          empty.
       d. The tickets, in lifecycle order (bd-6fkgvo), from
          `GET /api/issues/lifecycle` — every open ticket with its state,
          column, step, blockers and attention, in dispatch order. Each ticket
          appears in exactly one section:
            1. Needs attention — every ticket with attention, the
               coordinator's first, then the operator's, each with its reason.
               The routine verification wait (a Verifying ticket whose
               attention is still the coordinator's `awaiting_verification`)
               is not listed here: that is what the Verifying section is.
            2. In progress — with its step.
            3. Merging — with its step and PR.
            4. Verifying — merged, waiting for someone to restart the server
               and observe the new path, with the age of the wait.
            5. Ready — in dispatch order.
            6. Blocked — with the blockers it is waiting on.
            7. Backlog — a count.
          Epics stay off, as on the board.
       e. Active workers — the live runs: ticket, run kind and state, step,
          scoped to this workspace.
       f. Coordinator Inbox — unread messages for this workspace's coordinator.
          Omitted when empty.

  ## Standing Orders are data, not code

  The orders live in per-domain workspace config (`config.standing_orders`),
  not hardcoded here — arbiter is a shared tool, so one fleet's doctrine must
  not leak into every install. Each domain carries its own orders; setting or
  clearing them is a config change, no rebuild required. Each entry is either a
  short imperative string or a `{"title", "detail"}` object.

  ## What's intentionally NOT in v1

    * MergeQueue merge-queue items (no server-side endpoint yet).
    * Recent audit-log entries (no server-side endpoint yet).
    * Open epic / parent-task progress (no dedicated endpoint yet).

  ## `--json` shape

  Emits a JSON object with three keys:

      {
        "scheduler": {"state": "draining", "safe_to_restart": false, "in_flight": [...], ...},
        "coordinator_inbox": [...],
        "workspaces": [
          {
            "workspace": {...},
            "standing_orders": [...],
            "repo_standing_orders": {"<repo>": [...]},
            "rig_standing_orders": {"<repo>": [...]},  // deprecated alias, dual-emitted
            "needs_attention": [...],
            "in_progress": [...],
            "merging": [...],
            "verifying": [...],
            "awaiting_verification": [...],  // deprecated alias of verifying
            "ready": [...],
            "blocked": [...],
            "backlog_count": 3,
            "workers": [...],
            "coordinator_inbox": [...]
          }
        ]
      }

  ## Flags

    * `--json` — emit a single machine-readable JSON blob instead of the
      labelled text sections.
  """

  alias ArbiterCli.{Client, Output, RunLabel, SchedulerState}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      sections = gather()

      case mode do
        :json -> IO.puts(Jason.encode!(to_json(sections)))
        :text -> emit_text(sections)
      end
    end
  end

  defp to_json(sections) do
    %{
      scheduler: unwrap(sections.scheduler),
      coordinator_inbox: unwrap(sections.global_coordinator_inbox),
      workspaces: Enum.map(sections.workspaces, &workspace_to_json/1)
    }
  end

  defp workspace_to_json(%{} = ws_section) do
    repo_standing_orders = Map.new(ws_section.repo_standing_orders)

    %{
      workspace: ws_section.workspace,
      standing_orders: unwrap(ws_section.standing_orders),
      # "repo_standing_orders" is canonical; "rig_standing_orders" is
      # dual-emitted alongside it as a deprecated legacy key so existing
      # consumers keep working (bd-1aw9dl).
      repo_standing_orders: repo_standing_orders,
      rig_standing_orders: repo_standing_orders,
      workers: unwrap(ws_section.workers),
      coordinator_inbox: unwrap(ws_section.coordinator_inbox)
    }
    |> Map.merge(tickets_to_json(ws_section.tickets))
  end

  defp workspace_to_json({:error, msg}), do: %{"error" => msg}

  defp tickets_to_json({:ok, sections}) do
    sections
    |> Map.put(:backlog_count, length(sections.backlog))
    |> Map.delete(:backlog)
    # Deprecated alias for one release: the section used to be keyed so.
    |> Map.put(:awaiting_verification, sections.verifying)
  end

  defp tickets_to_json({:error, msg}), do: %{tickets: %{"error" => msg}}

  defp unwrap({:ok, val}), do: val
  defp unwrap({:error, msg}), do: %{"error" => msg}

  # ---- gather ------------------------------------------------------------

  defp gather do
    workspaces_result = gather_workspaces()

    workspace_sections =
      case workspaces_result do
        {:ok, list} -> Enum.map(list, &gather_workspace_section/1)
        {:error, _} = err -> [err]
      end

    %{
      scheduler: gather_scheduler(),
      global_coordinator_inbox: gather_global_coordinator_inbox(),
      workspaces: workspace_sections
    }
  end

  defp gather_scheduler do
    case SchedulerState.fetch() do
      {:ok, body} -> {:ok, body}
      {:error, %Client.Error{message: msg}} -> {:error, msg}
    end
  end

  defp gather_workspaces do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_workspace_section(ws) do
    ws_id = ws["id"]

    %{
      workspace: ws,
      standing_orders: gather_standing_orders(ws),
      repo_standing_orders: gather_repo_standing_orders(ws),
      workers: gather_workers(ws_id),
      tickets: gather_tickets(ws_id),
      coordinator_inbox: gather_coordinator_inbox(ws_id)
    }
  end

  # Standing Orders are per-domain operating disciplines carried in workspace
  # config (`config.standing_orders`). Already embedded in the workspace map,
  # so there's no extra API round-trip.
  defp gather_standing_orders(%{"config" => %{"standing_orders" => orders}})
       when is_list(orders),
       do: {:ok, orders}

  defp gather_standing_orders(_), do: {:ok, []}

  # Repo-scoped standing orders live alongside the path/target_branch overrides
  # in `config.repo_paths.<repo>.standing_orders` — same place as
  # `arb workspace standing-order add --repo`. Only repos that carry at least
  # one order are returned, in `[{repo, orders}]` form so text rendering can
  # walk it in order and JSON can turn it into a map.
  defp gather_repo_standing_orders(%{"config" => config}) when is_map(config) do
    repo_paths = config["repo_paths"] || %{}

    repo_paths
    |> Enum.map(fn {repo, entry} -> {repo, repo_standing_orders(entry)} end)
    |> Enum.reject(fn {_repo, orders} -> orders == [] end)
  end

  defp gather_repo_standing_orders(_), do: []

  defp repo_standing_orders(%{"standing_orders" => orders}) when is_list(orders), do: orders
  defp repo_standing_orders(_), do: []

  # Up to 5 most recent unread messages addressed to the coordinator. The REST
  # index already sorts newest-first, so a take/2 gives "most recent".
  defp gather_global_coordinator_inbox do
    case Client.get("/api/messages", to_ref: "coordinator", unread: "true") do
      {:ok, %{"data" => list}} -> {:ok, list}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp gather_workers(ws_id) do
    case Client.get("/api/workers", workspace_id: ws_id) do
      {:ok, %{"data" => list}} -> {:ok, Enum.filter(list, &(&1["workspace_id"] == ws_id))}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  # bd-6fkgvo: every open ticket in the workspace, projected (state, column,
  # step, blockers, attention) and in dispatch order, grouped into the
  # lifecycle sections.
  defp gather_tickets(ws_id) do
    case Client.get("/api/issues/lifecycle", workspace_id: ws_id) do
      {:ok, %{"data" => list}} -> {:ok, group_tickets(list)}
      {:ok, _} -> {:ok, group_tickets([])}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  @columns %{
    "in_progress" => :in_progress,
    "merging" => :merging,
    "verifying" => :verifying,
    "ready" => :ready,
    "blocked" => :blocked,
    "backlog" => :backlog
  }

  # Each ticket lands in exactly one section: attention wins over the column
  # (except the routine verification wait, which is the Verifying section),
  # and a ticket with no column this surface shows (closed) lands nowhere.
  # Order within a section is the server's dispatch order, but for Needs
  # attention, which leads with the coordinator's items.
  defp group_tickets(list) do
    empty = Map.new([:needs_attention | Map.values(@columns)], &{&1, []})

    list
    |> Enum.reduce(empty, fn t, acc ->
      case section(t) do
        nil -> acc
        key -> Map.update!(acc, key, &[t | &1])
      end
    end)
    |> Map.new(fn {key, tickets} -> {key, Enum.reverse(tickets)} end)
    |> Map.update!(:needs_attention, fn tickets ->
      Enum.sort_by(tickets, &owner_rank(get_in(&1, ["attention", "owner"])))
    end)
  end

  defp section(%{"attention" => %{} = attention} = t) do
    if routine_verification?(t, attention), do: :verifying, else: :needs_attention
  end

  defp section(t), do: Map.get(@columns, t["column"])

  defp routine_verification?(t, attention) do
    t["column"] == "verifying" and attention["cause"] == "awaiting_verification" and
      attention["owner"] == "coordinator"
  end

  defp owner_rank("coordinator"), do: 0
  defp owner_rank(_operator), do: 1

  defp gather_coordinator_inbox(ws_id) do
    case Client.get("/api/messages", to_ref: "coordinator", workspace_id: ws_id, unread: "true") do
      {:ok, %{"data" => list}} -> {:ok, Enum.filter(list, &(&1["workspace_id"] == ws_id))}
      {:ok, _} -> {:ok, []}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  # ---- render ------------------------------------------------------------

  defp emit_text(sections) do
    emit_scheduler(sections.scheduler)
    maybe_emit_global_coordinator_inbox(sections.global_coordinator_inbox)
    Enum.each(sections.workspaces, &emit_workspace_block/1)
  end

  defp emit_workspace_block(%{} = ws_section) do
    ws = ws_section.workspace
    IO.puts("== Workspace: #{ws["name"]} (#{ws["prefix"]}) ==")
    IO.puts("  name:    #{ws["name"]}")
    IO.puts("  prefix:  #{ws["prefix"]}")
    IO.puts("  id:      #{ws["id"]}")

    tracker_type = get_in(ws, ["config", "tracker", "type"]) || "none"
    IO.puts("  tracker: #{tracker_type}")

    emit_security_posture(ws["security_posture"], ws["config"])
    IO.puts("")

    maybe_emit_standing_orders_section(ws_section.standing_orders)
    emit_repo_standing_orders_sections(ws_section.repo_standing_orders)
    emit_ticket_sections(ws_section.tickets)
    emit_workers_section(ws_section.workers, "worker")
    IO.puts("")
    maybe_emit_coordinator_inbox(ws_section.coordinator_inbox)
  end

  defp emit_workspace_block({:error, msg}) do
    IO.puts("== Workspaces ==")
    IO.puts("  (could not load: #{msg})")
    IO.puts("")
  end

  # Omitted entirely when the domain carries no orders.
  defp maybe_emit_standing_orders_section({:ok, []}), do: :ok

  defp maybe_emit_standing_orders_section({:ok, orders}) do
    IO.puts("== Standing Orders ==")
    Enum.each(orders, fn o -> IO.puts("  " <> standing_order_line(o)) end)
    IO.puts("")
  end

  defp maybe_emit_standing_orders_section(_), do: :ok

  # One section per repo that carries at least one order — omitted entirely
  # when no repo in this workspace has any.
  defp emit_repo_standing_orders_sections(repo_orders) do
    Enum.each(repo_orders, fn {repo, orders} ->
      IO.puts("== Standing Orders — #{repo} ==")
      Enum.each(orders, fn o -> IO.puts("  " <> standing_order_line(o)) end)
      IO.puts("")
    end)
  end

  # An order is either a short imperative string or a {title, detail} object.
  defp standing_order_line(%{"title" => title} = order) do
    case order["detail"] do
      detail when is_binary(detail) and detail != "" -> "[ ] #{title} — #{detail}"
      _ -> "[ ] #{title}"
    end
  end

  defp standing_order_line(order) when is_binary(order), do: "[ ] #{order}"
  defp standing_order_line(order), do: "[ ] #{inspect(order)}"

  # Omitted entirely when there's no unread coordinator mail.
  # bd-9fgg04: a paused scheduler still draining must not read as idle — the
  # in-flight list is exactly the work a restart would kill.
  defp emit_scheduler({:ok, body}) do
    IO.puts("== Scheduler ==")
    IO.puts("  " <> SchedulerState.headline(body))
    Enum.each(SchedulerState.entry_lines(body), &IO.puts("    " <> &1))
    emit_quota_hold(body["quota_hold"])
    emit_paused_providers(body["paused_providers"])
    IO.puts("")
  end

  defp emit_scheduler({:error, msg}) do
    IO.puts("== Scheduler ==")
    IO.puts("  (unavailable: #{msg})")
    IO.puts("")
  end

  # bd-1qjv3j: the board-wide quota/auth hold, account-qualified, so a coordinator
  # sees which provider account is held before it plans a dispatch.
  defp emit_quota_hold(reason) when is_binary(reason), do: IO.puts("  held — #{reason}")
  defp emit_quota_hold(_), do: :ok

  # bd-5ef587: a paused provider is dropped from all routing — the coordinator
  # must see who paused it, when and why before it plans any dispatch.
  defp emit_paused_providers([_ | _] = rows) do
    IO.puts("  paused providers:")

    Enum.each(rows, fn r ->
      IO.puts(
        "    #{r["label"] || r["target"]} — #{r["reason"] || "no reason given"} " <>
          "(by #{r["by"] || "unknown"}, #{r["at"] || "unknown time"})"
      )
    end)
  end

  defp emit_paused_providers(_), do: :ok

  defp maybe_emit_global_coordinator_inbox({:ok, []}), do: :ok

  defp maybe_emit_global_coordinator_inbox({:ok, list}) do
    IO.puts("== Global Coordinator Inbox (#{length(list)} unread) ==")

    list
    |> Enum.take(5)
    |> Enum.each(fn m -> IO.puts("  " <> inbox_line(m)) end)

    IO.puts("")
  end

  defp maybe_emit_global_coordinator_inbox(_), do: :ok

  # Omitted entirely when there's no unread coordinator mail.
  defp maybe_emit_coordinator_inbox({:ok, []}), do: :ok

  defp maybe_emit_coordinator_inbox({:ok, list}) do
    IO.puts("== Coordinator Inbox (#{length(list)} unread) ==")

    list
    |> Enum.take(5)
    |> Enum.each(fn m -> IO.puts("  " <> inbox_line(m)) end)

    IO.puts("")
  end

  defp maybe_emit_coordinator_inbox(_), do: :ok

  # `[bd-9bn4n9] failure    — Worker exited with code 1 (5m ago)`
  defp inbox_line(m) do
    task_ref = m["task_ref"] || m["directive_ref"] || "-"
    kind = m["kind"] |> to_string() |> String.pad_trailing(10)
    gist = m["subject"] || m["body"] || ""
    gist = gist |> to_string() |> String.split("\n") |> List.first() |> truncate(60)
    "[#{task_ref}] #{kind} — #{gist}#{age_suffix(m["inserted_at"])}"
  end

  defp age_suffix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> " (#{humanize(DateTime.diff(DateTime.utc_now(), dt, :second))})"
      _ -> ""
    end
  end

  defp age_suffix(_), do: ""

  defp humanize(s) when s < 60, do: "#{max(s, 0)}s ago"
  defp humanize(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp humanize(s) when s < 86_400, do: "#{div(s, 3600)}h ago"
  defp humanize(s), do: "#{div(s, 86_400)}d ago"

  # The resolved worker security posture (server-computed; see
  # ArbiterWeb.Api.WorkspaceJSON). Surfaced so a fresh coordinator session sees,
  # up front, what a worker spawned in this domain may and may not do.
  defp emit_security_posture(%{} = posture, config) do
    sandbox = posture["sandbox"] || %{}
    deny = List.wrap(posture["deny"])
    safe = List.wrap(posture["safe_defaults"])
    allow = List.wrap(posture["allow"])
    missing = List.wrap(posture["safe_defaults_exclude"])

    net = if Map.get(sandbox, "network", true), do: "on", else: "tools-off"

    IO.puts("  security:")
    IO.puts("    mode:    #{posture["mode"] || "auto"}")

    IO.puts(
      "    sandbox: fs=#{Map.get(sandbox, "filesystem", "worktree")} net=#{net}" <>
        " enabled=#{Map.get(sandbox, "enabled", true)}"
    )

    IO.puts(
      "    deny:    #{length(safe)} safe-default + #{length(deny)} custom" <>
        ", allow: #{length(allow)}"
    )

    # bd-1abj7u: `write_confinement` names WHAT actually confines this
    # provider's writes to the worktree under the resolved policy — distinct
    # from `policy_enforced` (whether the adapter's own deny-list contract is
    # honoured at all). An operator needs both to know, e.g., that agy is not
    # `:strict`-eligible even though it enforces its own deny list.
    IO.puts(
      "    provider: #{posture["provider"] || "unknown"}" <>
        " (policy_enforced=#{posture["policy_enforced"] || false}" <>
        ", write_confinement=#{posture["write_confinement"] || "none"})"
    )

    emit_security_posture_warnings(posture, config, missing)
  end

  defp emit_security_posture(_, _config), do: :ok

  # bd-4420va: name every current default category this workspace's resolved
  # policy excludes, so an operator sees it here rather than discovering it
  # live in a worker's --settings. bd-8xy1mf: the same write-jail gap `arb
  # server doctor` reports, so a fresh coordinator session sees it here too.
  defp emit_security_posture_warnings(posture, config, missing) do
    if missing != [] do
      IO.puts("    WARNING: missing safe-default categories: #{Enum.join(missing, ", ")}")
    end

    if has_legacy_safe_defaults_key?(config) do
      IO.puts(
        "    WARNING: legacy safe_defaults key present in config — it is ignored, use " <>
          "safe_defaults_exclude"
      )
    end

    if warning = posture["write_jail_warning"] do
      IO.puts("    WARNING: #{warning}")
    end
  end

  defp has_legacy_safe_defaults_key?(config) when is_map(config) do
    config
    |> get_in(["agent", "security", "permissions"])
    |> case do
      %{} = permissions -> Map.has_key?(permissions, "safe_defaults")
      _ -> false
    end
  end

  defp has_legacy_safe_defaults_key?(_config), do: false

  defp emit_workers_section({:ok, []}, worker) do
    IO.puts("== Active #{worker}s ==")
    IO.puts("  (none)")
  end

  defp emit_workers_section({:ok, list}, worker) do
    IO.puts("== Active #{worker}s (#{length(list)}) ==")

    Enum.each(list, fn p ->
      # Claude-driven workers have a frozen workflow step; show their live
      # stream-derived activity instead. See bd-c919xj.
      step =
        if p["claude_session"],
          do: "activity=#{activity_label(p)}",
          else: "step=#{p["current_step"]}"

      IO.puts(
        "  #{p["task_id"]}  #{RunLabel.label(p)}  #{step}  repo=#{p["repo"]}" <>
          RunLabel.run_suffix(p)
      )
    end)
  end

  defp emit_workers_section({:error, msg}, worker) do
    IO.puts("== Active #{worker}s ==")
    IO.puts("  (error: #{msg})")
  end

  # ---- the lifecycle sections (bd-6fkgvo) --------------------------------

  defp emit_ticket_sections({:ok, sections}) do
    emit_section("Needs attention", sections.needs_attention, &attention_line/1)
    emit_section("In progress", sections.in_progress, &in_progress_line/1)
    emit_section("Merging", sections.merging, &merging_line/1)
    emit_section("Verifying", sections.verifying, &verifying_line/1)

    if sections.verifying != [] do
      IO.puts(
        "  → restart the server, observe each, then: " <>
          ~s(arb ticket verify <id> --observed "<evidence>")
      )

      IO.puts("")
    end

    emit_section("Ready", sections.ready, &ready_line/1)
    emit_section("Blocked", sections.blocked, &blocked_line/1)
    IO.puts("== Backlog (#{length(sections.backlog)}) ==")
    IO.puts("")
  end

  defp emit_ticket_sections({:error, msg}) do
    IO.puts("== Tickets ==")
    IO.puts("  (error: #{msg})")
    IO.puts("")
  end

  defp emit_section(title, [], _line) do
    IO.puts("== #{title} ==")
    IO.puts("  (none)")
    IO.puts("")
  end

  defp emit_section(title, tickets, line) do
    IO.puts("== #{title} (#{length(tickets)}) ==")
    Enum.each(tickets, &IO.puts("  " <> line.(&1)))
    IO.puts("")
  end

  # `bd-1  coordinator  <reason>  — <title> (in_progress, 5m ago)`
  defp attention_line(t) do
    a = t["attention"]
    note = if blank?(a["note"]), do: "", else: " [note: #{truncate(a["note"], 60)}]"

    "#{t["id"]}  #{a["owner"]}  #{a["reason"]}#{note}  — #{truncate(t["title"], 60)}" <>
      " (#{t["column"]}#{age_suffix_inline(a["since"])})"
  end

  defp in_progress_line(t),
    do: "#{t["id"]}  step=#{t["step"] || "-"}  P#{t["priority"]}  #{truncate(t["title"], 70)}"

  defp merging_line(t) do
    pr = if blank?(t["pr_ref"]), do: "", else: "  PR #{t["pr_ref"]}"
    "#{t["id"]}  step=#{t["step"] || "-"}#{pr}  #{truncate(t["title"], 60)}"
  end

  defp verifying_line(t),
    do: "#{t["id"]}  #{truncate(t["title"], 70)}#{age_suffix(t["awaiting_verification_at"])}"

  defp ready_line(t),
    do: "#{t["id"]}  P#{t["priority"]}  #{t["issue_type"]}  #{truncate(t["title"], 80)}"

  defp blocked_line(t) do
    "#{t["id"]}  P#{t["priority"]}  #{truncate(t["title"], 60)}  ← waiting on " <>
      Enum.join(List.wrap(t["blocked_by"]), ", ")
  end

  defp age_suffix_inline(iso) do
    case age_suffix(iso) do
      "" -> ""
      " (" <> rest -> ", " <> String.trim_trailing(rest, ")")
    end
  end

  defp blank?(v), do: v in [nil, ""]

  defp truncate(nil, _), do: ""

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end

  # Activity is exposed by the JSON API as a map (%{"label", ...}) or null;
  # render its label, falling back to "working" until the first event lands.
  defp activity_label(p) do
    case p["activity"] do
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> "working"
    end
  end
end
