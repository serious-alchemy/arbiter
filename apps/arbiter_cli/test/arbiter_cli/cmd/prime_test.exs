defmodule ArbiterCli.Cmd.PrimeTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Prime

  # All /api/messages requests (coordinator + per-workspace coordinator) share
  # a single stub matched by path; query params are not matched by stub_routes.
  defp stub_all(workspaces, workers, tickets, messages \\ []) do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => workspaces}, 200}},
      {{"get", "/api/workers"}, {%{"data" => workers}, 200}},
      {{"get", "/api/issues/lifecycle"}, {%{"data" => tickets}, 200}},
      {{"get", "/api/attention"}, {%{"attention" => attention_items(tickets)}, 200}},
      {{"get", "/api/messages"}, {%{"data" => messages}, 200}}
    ])
  end

  # What `GET /api/attention` serves for these lifecycle tickets: one flat item
  # per ticket carrying attention.
  defp attention_items(tickets) do
    for %{"attention" => %{} = a} = t <- tickets do
      Map.merge(a, %{
        "ticket_id" => t["id"],
        "title" => t["title"],
        "state" => t["column"],
        "workspace_id" => t["workspace_id"]
      })
    end
  end

  # bd-6fkgvo — the per-workspace lifecycle sections, from
  # `GET /api/issues/lifecycle` (every open ticket, projected, in dispatch
  # order).
  describe "lifecycle sections" do
    defp stub_with_tickets(tickets) do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        tickets
      )
    end

    defp two_hours_ago,
      do: DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_iso8601()

    defp ticket(id, column, extra \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "title" => "title of #{id}",
          "priority" => 2,
          "issue_type" => "feature",
          "column" => column,
          "step" => nil,
          "blocked_by" => [],
          "attention" => nil,
          "workspace_id" => "ws-1"
        },
        extra
      )
    end

    defp attention(owner, cause, reason) do
      %{"owner" => owner, "cause" => cause, "reason" => reason, "waiting_on" => "x"}
    end

    # One ticket in every column, plus attention of both owners. Dispatch
    # order is the server's; the Ready pair arrives in it.
    defp every_column do
      [
        ticket("bd-ready1", "ready", %{"priority" => 0}),
        ticket("bd-op", "merging", %{
          "step" => "merge_blocked",
          "attention" => attention("operator", "merge_blocked", "needs an approval you can give")
        }),
        ticket("bd-coord", "in_progress", %{
          "step" => "implementing",
          "attention" => attention("coordinator", "run_crashed", "the run crashed")
        }),
        ticket("bd-prog", "in_progress", %{"step" => "in_review"}),
        ticket("bd-merge", "merging", %{"step" => "waiting_ci", "pr_ref" => "#12"}),
        ticket("bd-verify", "verifying", %{
          "awaiting_verification_at" => two_hours_ago(),
          "attention" =>
            attention("coordinator", "awaiting_verification", "restart and observe it")
        }),
        ticket("bd-ready2", "ready", %{"priority" => 3}),
        ticket("bd-blocked", "blocked", %{"blocked_by" => ["bd-prog", "bd-merge"]}),
        ticket("bd-back1", "backlog"),
        ticket("bd-back2", "backlog")
      ]
    end

    @headers [
      "== Needs attention",
      "== In progress",
      "== Merging",
      "== Verifying",
      "== Ready",
      "== Blocked",
      "== Backlog"
    ]

    # The text of each section, keyed by its header prefix.
    defp sections(out) do
      out
      |> String.split("\n")
      |> Enum.chunk_while(
        nil,
        fn line, acc ->
          cond do
            String.starts_with?(line, "== ") and acc -> {:cont, acc, {line, []}}
            String.starts_with?(line, "== ") -> {:cont, {line, []}}
            acc -> {:cont, {elem(acc, 0), [line | elem(acc, 1)]}}
            true -> {:cont, nil}
          end
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, acc, nil}
        end
      )
      |> Enum.flat_map(fn {header, lines} ->
        case Enum.find(@headers, &String.starts_with?(header, &1)) do
          nil -> []
          key -> [{key, Enum.reverse(lines)}]
        end
      end)
    end

    test "prints the sections in lifecycle order" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      positions = Enum.map(@headers, fn h -> out |> :binary.match(h) |> elem(0) end)
      assert positions == Enum.sort(positions)
    end

    test "every ticket appears in exactly one section" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      sections = sections(out)

      expected = %{
        "== Needs attention" => ["bd-coord", "bd-op"],
        "== In progress" => ["bd-prog"],
        "== Merging" => ["bd-merge"],
        "== Verifying" => ["bd-verify"],
        "== Ready" => ["bd-ready1", "bd-ready2"],
        "== Blocked" => ["bd-blocked"],
        "== Backlog" => []
      }

      for ticket <- every_column(), id = ticket["id"], not String.starts_with?(id, "bd-back") do
        holders =
          for {header, lines} <- sections,
              Enum.any?(lines, &String.starts_with?(String.trim_leading(&1), id <> " ")),
              do: header

        assert length(holders) == 1, "#{id} appears in #{inspect(holders)}"
        [holder] = holders
        assert id in expected[holder], "#{id} landed in #{holder}"
      end

      refute out =~ "bd-back1"
      assert out =~ "== Backlog (2) =="
    end

    test "needs attention lists the coordinator's items before the operator's, with reasons" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      {_, lines} = Enum.find(sections(out), &(elem(&1, 0) == "== Needs attention"))
      text = Enum.join(lines, "\n")

      assert text =~ ~r/bd-coord .*coordinator.*the run crashed/
      assert text =~ ~r/bd-op .*operator.*needs an approval you can give/
      assert :binary.match(text, "bd-coord") < :binary.match(text, "bd-op")
    end

    test "rows carry their step, PR, blockers and verification age" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      assert out =~ ~r/bd-prog .*step=in_review/
      assert out =~ ~r/bd-merge .*step=waiting_ci.*#12/
      assert out =~ ~r/bd-blocked .*waiting on bd-prog, bd-merge/
      assert out =~ ~r/bd-verify .*2h ago/
      assert out =~ "arb ticket verify <id>"
      assert :binary.match(out, "bd-ready1") < :binary.match(out, "bd-ready2")
    end

    test "has no Review parked section, and no refined-blind Ready issues section" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      refute out =~ "Review parked"
      refute out =~ "Ready issues"
      refute out =~ "Awaiting verification"
    end

    test "a verification handed off to the operator is attention, not routine" do
      stub_with_tickets([
        ticket("bd-verify", "verifying", %{
          "attention" => attention("operator", "awaiting_verification", "only you can observe it")
        })
      ])

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      assert out =~ "== Needs attention (1) =="
      assert out =~ "== Verifying =="
    end

    test "--json carries each section, and the backlog as a count" do
      stub_with_tickets(every_column())

      {out, _err, 0} = capture(fn -> Prime.run(["--json"]) end)
      assert {:ok, %{"workspaces" => [ws]}} = Jason.decode(out)

      ids = fn key -> Enum.map(ws[key], & &1["id"]) end
      assert ids.("needs_attention") == ["bd-coord", "bd-op"]
      assert ids.("in_progress") == ["bd-prog"]
      assert ids.("merging") == ["bd-merge"]
      assert ids.("verifying") == ["bd-verify"]
      assert ids.("ready") == ["bd-ready1", "bd-ready2"]
      assert ids.("blocked") == ["bd-blocked"]
      assert ws["backlog_count"] == 2
      refute Map.has_key?(ws, "review_parked")
    end

    test "awaiting_ci tickets appear under Merging in text and json mode" do
      tickets = [
        ticket("bd-wait-ci", "merging", %{
          "step" => "awaiting_ci",
          "title" => "Awaiting CI on review"
        }),
        ticket("bd-active", "in_progress", %{
          "step" => "implementing",
          "title" => "Implementing thing"
        })
      ]

      stub_with_tickets(tickets)

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      sec = Map.new(sections(out))
      merging_text = Map.get(sec, "== Merging", []) |> Enum.join("\n")
      in_prog_text = Map.get(sec, "== In progress", []) |> Enum.join("\n")

      assert merging_text =~ "bd-wait-ci"
      assert merging_text =~ "step=awaiting_ci"
      assert in_prog_text =~ "bd-active"
      refute in_prog_text =~ "bd-wait-ci"

      {json_out, _err, 0} = capture(fn -> Prime.run(["--json"]) end)
      assert {:ok, %{"workspaces" => [ws]}} = Jason.decode(json_out)
      assert Enum.map(ws["merging"], & &1["id"]) == ["bd-wait-ci"]
      assert Enum.map(ws["in_progress"], & &1["id"]) == ["bd-active"]
    end

    # bd-abg443: a quota-held active ticket reads Blocked with its hold.
    test "a quota-held ticket appears under Blocked with its hold reason and resume time" do
      reason = "held — quota (claude:default 5h ≥ paced line; resumes ~15:30Z)"

      stub_with_tickets([
        ticket("bd-held", "blocked", %{
          "blocked_by" => [],
          "hold" => %{"reason" => reason, "resumes_at" => "2026-10-06T15:30:00Z"}
        })
      ])

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      sec = Map.new(sections(out))

      assert sec |> Map.get("== Blocked", []) |> Enum.join("\n") =~
               ~r/bd-held .*#{Regex.escape(reason)}/u

      assert sec |> Map.get("== In progress", []) |> Enum.join("\n") =~ "(none)"
    end

    test "Needs attention is the /api/attention queue, not a filter of the lifecycle read" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "d", "prefix" => "bd", "config" => %{}}]}, 200}},
        {{"get", "/api/workers"}, {%{"data" => []}, 200}},
        {{"get", "/api/issues/lifecycle"},
         {%{
            "data" => [
              ticket("bd-life", "in_progress", %{
                "attention" => attention("coordinator", "run_crashed", "lifecycle only")
              })
            ]
          }, 200}},
        {{"get", "/api/attention"},
         {%{
            "attention" => [
              %{
                "ticket_id" => "bd-queue",
                "title" => "from the queue",
                "state" => "active",
                "owner" => "operator",
                "reason" => "queue reason"
              }
            ]
          }, 200}},
        {{"get", "/api/messages"}, {%{"data" => []}, 200}}
      ])

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      [{_, lines}] = Enum.filter(sections(out), &match?({"== Needs attention", _}, &1))
      text = Enum.join(lines, "\n")

      assert text =~ "bd-queue"
      assert text =~ "queue reason"
      refute text =~ "bd-life"
    end

    test "an unreadable attention read is marked, not omitted" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "d", "prefix" => "bd", "config" => %{}}]}, 200}},
        {{"get", "/api/workers"}, {%{"data" => []}, 200}},
        {{"get", "/api/issues/lifecycle"}, {%{"data" => []}, 200}},
        {{"get", "/api/attention"}, {%{"error" => "boom"}, 500}},
        {{"get", "/api/messages"}, {%{"data" => []}, 200}}
      ])

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      assert out =~ "== Tickets =="
      assert out =~ "(error:"
    end

    test "an unreadable lifecycle read is marked, not omitted" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "d", "prefix" => "bd", "config" => %{}}]}, 200}},
        {{"get", "/api/workers"}, {%{"data" => []}, 200}},
        {{"get", "/api/issues/lifecycle"}, {%{"error" => "boom"}, 500}},
        {{"get", "/api/attention"}, {%{"attention" => []}, 200}},
        {{"get", "/api/messages"}, {%{"data" => []}, 200}}
      ])

      {out, _err, 0} = capture(fn -> Prime.run([]) end)
      assert out =~ "== Tickets =="
      assert out =~ "(error:"
    end
  end

  describe "text mode" do
    # bd-dtdeff: a Ready card the scheduler is holding names the hold.
    test "a held Ready card shows its hold reason; an unheld one shows none" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [
          %{
            "id" => "bd-held",
            "priority" => 3,
            "issue_type" => "feature",
            "title" => "Held card",
            "column" => "ready",
            "hold_reason" => "held — provider constraint (require claude: at capacity)"
          },
          %{
            "id" => "bd-free",
            "priority" => 3,
            "issue_type" => "feature",
            "title" => "Free card",
            "column" => "ready"
          }
        ]
      )

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      [held] = Regex.run(~r/^.*bd-held.*$/m, out)
      [free] = Regex.run(~r/^.*bd-free.*$/m, out)
      assert held =~ "held — provider constraint (require claude: at capacity)"
      refute free =~ "held"
    end

    test "prints workspace header, workers, and ready tasks" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "tracker" => %{"type" => "jira"}
            }
          }
        ],
        [
          %{
            "task_id" => "bd-001",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "test/repo",
            "workspace_id" => "ws-1"
          }
        ],
        [
          %{
            "id" => "bd-002",
            "priority" => 1,
            "issue_type" => "bug",
            "title" => "Fix the thing",
            "column" => "ready"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Workspace: default (bd) =="
      assert out =~ "default"
      assert out =~ "tracker: jira"

      assert out =~ "== Active workers (1) =="
      assert out =~ "bd-001"
      assert out =~ "step=implement"

      assert out =~ "== Ready (1) =="
      assert out =~ "bd-002"
      assert out =~ "Fix the thing"
    end

    # bd-1uu19b AC7: a ReviewGate reviewer's worker carries no workspace of its
    # own; the server reports its run under the ticket's workspace, so the
    # active-workers section lists it — labelled with its kind and state.
    test "lists a reviewer run as its ticket's current run, in the run vocabulary" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [
          %{
            "task_id" => "bd-001",
            "run_task_id" => "bd-001#review",
            "kind" => "review",
            "state" => "working",
            "outcome" => nil,
            "current_step" => "claude",
            "repo" => "test/repo",
            "workspace_id" => "ws-1"
          },
          %{
            "task_id" => "bd-002",
            "run_task_id" => "bd-002",
            "kind" => "fix_pass",
            "state" => "finished",
            "outcome" => "failed",
            "current_step" => "claude",
            "repo" => "test/repo",
            "workspace_id" => "ws-1"
          }
        ],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Active workers (2) =="
      assert out =~ ~r/bd-001  review working .*run=bd-001#review/
      assert out =~ ~r/bd-002  fix_pass finished \(failed\)/
      refute out =~ "status="
    end

    test "lists all workspaces when multiple are configured" do
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "acme", "prefix" => "ac", "config" => %{}}
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Workspace: default (bd) =="
      assert out =~ "== Workspace: acme (ac) =="

      default_at = :binary.match(out, "== Workspace: default (bd) ==") |> elem(0)
      acme_at = :binary.match(out, "== Workspace: acme (ac) ==") |> elem(0)
      assert default_at < acme_at
    end

    test "renders the security posture section when the workspace carries one" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => ["Bash(docker:*)"],
              "safe_defaults" => ["no_destructive_fs", "no_force_push"],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => false}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "security:"
      assert out =~ "mode:    bypass"
      assert out =~ "net=tools-off"
      assert out =~ "2 safe-default + 1 custom"
    end

    # bd-1abj7u: an operator needs to see, up front, that a configured
    # provider (agy/gemini here) is not `:strict`-eligible even though it
    # enforces its own deny-list contract (`policy_enforced`).
    test "renders provider/policy_enforced/write_confinement from the security posture" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{},
            "security_posture" => %{
              "mode" => "strict",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
              "provider" => "gemini",
              "policy_enforced" => false,
              "write_confinement" => "none"
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~
               "provider: gemini (policy_enforced=false, write_confinement=none)"
    end

    # bd-4420va: a workspace whose resolved policy excludes a current default
    # category (vstim's old pinned safe_defaults list missing :no_public_upload
    # after v0.1.78) must show it here instead of staying silent.
    test "warns when the resolved posture is missing a current default category" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "vstim",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => ["no_destructive_fs", "no_force_push"],
              "safe_defaults_exclude" => ["no_public_upload", "no_gh_publish"],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "WARNING: missing safe-default categories: no_public_upload, no_gh_publish"
    end

    test "warns when a workspace config still carries the inert legacy safe_defaults key" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "vstim",
            "prefix" => "vs",
            "config" => %{
              "agent" => %{
                "security" => %{
                  "permissions" => %{
                    "safe_defaults" => ["no_destructive_fs", "no_force_push"]
                  }
                }
              }
            },
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~
               "WARNING: legacy safe_defaults key present in config — it is ignored, use safe_defaults_exclude"
    end

    # bd-8xy1mf: the same gap `arb server doctor`'s "agy write jail" check
    # reports must also be visible to a fresh coordinator session up front.
    test "warns when the workspace posture carries a write_jail_warning" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "vstim",
            "prefix" => "vs",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => [],
              "safe_defaults" => [],
              "safe_defaults_exclude" => [],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => true},
              "write_jail_warning" =>
                "agy write jail unavailable (bwrap (bwrap) not found on PATH) — writes are " <>
                  "not confined to the worktree outside :strict"
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~
               "WARNING: agy write jail unavailable (bwrap (bwrap) not found on PATH) — writes " <>
                 "are not confined to the worktree outside :strict"
    end

    test "empty workers and ready tasks render '(none)'" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Active workers =="
      assert out =~ "(none)"
      assert out =~ "== Ready =="
    end

    test "renders the Global Coordinator Inbox section when there is unread mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-1",
            "kind" => "failure",
            "directive_ref" => "bd-9bn4n9",
            "subject" => "Worker exited with code 1",
            "body" => "stderr tail...",
            "inserted_at" => "2026-05-28T11:55:00.000000Z"
          },
          %{
            "id" => "m-2",
            "kind" => "completion",
            "directive_ref" => "bd-6c6w82",
            "subject" => "GitHub adapter complete",
            "body" => "done",
            "inserted_at" => "2026-05-28T11:48:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      assert out =~ "== Global Coordinator Inbox (2 unread) =="
      assert out =~ "[bd-9bn4n9] failure"
      assert out =~ "Worker exited with code 1"
      assert out =~ "[bd-6c6w82] completion"
    end

    test "Global Coordinator Inbox appears before workspace blocks" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-1",
            "kind" => "failure",
            "directive_ref" => "bd-9bn4n9",
            "subject" => "Worker exited with code 1",
            "inserted_at" => "2026-05-28T11:55:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      inbox_at = :binary.match(out, "== Global Coordinator Inbox") |> elem(0)
      workspace_at = :binary.match(out, "== Workspace:") |> elem(0)
      assert inbox_at < workspace_at
    end

    test "omits the Global Coordinator Inbox section entirely when there is no unread mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Global Coordinator Inbox"
    end

    test "renders the Coordinator Inbox section when there is unread coordinator mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-3",
            "kind" => "escalation",
            "directive_ref" => "bd-abc",
            "subject" => "Worker needs direction",
            "body" => "please advise",
            "inserted_at" => "2026-05-28T12:00:00.000000Z",
            "workspace_id" => "ws-1"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      assert out =~ "== Coordinator Inbox"
      assert out =~ "[bd-abc] escalation"
      assert out =~ "Worker needs direction"
    end

    test "the Coordinator Inboxes show the 5 newest of an oldest-first unread queue" do
      msg = fn n ->
        %{
          "id" => "m-#{n}",
          "kind" => "escalation",
          "directive_ref" => "bd-n#{n}",
          "subject" => "subject #{n}",
          "inserted_at" => "2026-05-28T12:0#{n}:00.000000Z",
          "workspace_id" => "ws-1"
        }
      end

      # The REST unread queue is oldest-first; 7 messages, so 2 are cut.
      queue = Enum.map(1..7, msg)

      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        queue
      )

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      for section <- [
            "== Global Coordinator Inbox (7 unread) ==",
            "== Coordinator Inbox (7 unread) =="
          ] do
        [_, rest] = String.split(out, section, parts: 2)
        block = rest |> String.split("\n\n", parts: 2) |> hd()

        for n <- 3..7, do: assert(block =~ "[bd-n#{n}]")
        for n <- 1..2, do: refute(block =~ "[bd-n#{n}]")
      end
    end

    test "omits the Coordinator Inbox section when there is no unread coordinator mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Coordinator Inbox"
    end

    test "renders the Standing Orders section from config.standing_orders" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "standing_orders" => [
                "Watch the Coordinator inbox — stand a ~60s background poll.",
                %{
                  "title" => "Never boot a second Arbiter instance",
                  "detail" => "it sweeps live runs"
                },
                %{"title" => "No merge to main without the ReviewGate review gate"}
              ]
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Standing Orders =="
      assert out =~ "[ ] Watch the Coordinator inbox — stand a ~60s background poll."
      assert out =~ "[ ] Never boot a second Arbiter instance — it sweeps live runs"
      assert out =~ "[ ] No merge to main without the ReviewGate review gate"

      # Surfaced within the workspace block, before the work list.
      orders_at = :binary.match(out, "== Standing Orders ==") |> elem(0)
      ready_at = :binary.match(out, "== Needs attention") |> elem(0)
      assert orders_at < ready_at
    end

    test "omits the Standing Orders section entirely when config has none" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Standing Orders"
    end

    test "renders a per-repo Standing Orders section from repo_paths.<rig>.standing_orders" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "standing_orders" => ["Follow the PR template."],
              "repo_paths" => %{
                "client" => %{
                  "path" => "/home/rborn/dev/acme/client",
                  "standing_orders" => [
                    "If the work has an associated Figma design, link it in the Jira ticket."
                  ]
                },
                "server" => "/home/rborn/dev/acme/server"
              }
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Standing Orders =="
      assert out =~ "[ ] Follow the PR template."

      assert out =~ "== Standing Orders — client =="
      assert out =~ "[ ] If the work has an associated Figma design, link it in the Jira ticket."
      refute out =~ "== Standing Orders — server =="

      # Repo-scoped block comes after the global one, still ahead of the work list.
      global_at = :binary.match(out, "== Standing Orders ==") |> elem(0)
      repo_at = :binary.match(out, "== Standing Orders — client ==") |> elem(0)
      ready_at = :binary.match(out, "== Needs attention") |> elem(0)
      assert global_at < repo_at
      assert repo_at < ready_at
    end

    test "omits per-repo Standing Orders sections when no repo carries any" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "repo_paths" => %{"server" => "/home/rborn/dev/acme/server"}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Standing Orders —"
    end

    test "never shows an Operating Pitfalls section" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Operating Pitfalls"
    end
  end

  describe "--json mode" do
    test "emits a JSON object with coordinator_inbox and workspaces array" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert is_map(decoded)
      assert Map.has_key?(decoded, "coordinator_inbox")
      assert Map.has_key?(decoded, "workspaces")
      assert is_list(decoded["workspaces"])
      refute Map.has_key?(decoded, "field_guide_pitfalls")

      [ws] = decoded["workspaces"]
      assert Map.has_key?(ws, "workspace")
      assert Map.has_key?(ws, "workers")
      assert Map.has_key?(ws, "ready")
      assert Map.has_key?(ws, "standing_orders")
      assert Map.has_key?(ws, "coordinator_inbox")
    end

    test "workers and coordinator inbox are scoped to their own workspace" do
      # Both stubs return a mixed payload; client-side filtering must assign
      # each worker/message to only the workspace whose id matches.
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "acme", "prefix" => "ac", "config" => %{}}
        ],
        [
          %{
            "task_id" => "bd-001",
            "workspace_id" => "ws-1",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "test/repo"
          },
          %{
            "task_id" => "ac-001",
            "workspace_id" => "ws-2",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "other/repo"
          }
        ],
        [],
        [
          %{
            "id" => "m-ws1",
            "workspace_id" => "ws-1",
            "kind" => "escalation",
            "directive_ref" => "bd-001",
            "subject" => "default coordinator msg",
            "inserted_at" => "2026-05-28T12:00:00.000000Z"
          },
          %{
            "id" => "m-ws2",
            "workspace_id" => "ws-2",
            "kind" => "escalation",
            "directive_ref" => "ac-001",
            "subject" => "acme coordinator msg",
            "inserted_at" => "2026-05-28T12:00:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      [default_ws, acme_ws] = decoded["workspaces"]

      assert Enum.map(default_ws["workers"], & &1["task_id"]) == ["bd-001"]
      assert Enum.map(acme_ws["workers"], & &1["task_id"]) == ["ac-001"]

      assert length(default_ws["coordinator_inbox"]) == 1
      assert hd(default_ws["coordinator_inbox"])["id"] == "m-ws1"
      assert length(acme_ws["coordinator_inbox"]) == 1
      assert hd(acme_ws["coordinator_inbox"])["id"] == "m-ws2"
    end

    test "workspaces array has one entry per configured workspace" do
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "acme", "prefix" => "ac", "config" => %{}}
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert length(decoded["workspaces"]) == 2

      names = Enum.map(decoded["workspaces"], fn ws -> ws["workspace"]["name"] end)
      assert "default" in names
      assert "acme" in names
    end

    test "standing_orders carries the config list through --json" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"standing_orders" => ["Watch the Coordinator inbox"]}
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      [ws] = decoded["workspaces"]
      assert ws["standing_orders"] == ["Watch the Coordinator inbox"]
    end

    test "repo_standing_orders (canonical) and rig_standing_orders (legacy alias) both carry per-repo orders keyed by repo, through --json" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "repo_paths" => %{
                "client" => %{
                  "path" => "/x/client",
                  "standing_orders" => ["Link the Figma design."]
                },
                "server" => %{"path" => "/x/server"}
              }
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      [ws] = decoded["workspaces"]
      assert ws["repo_standing_orders"] == %{"client" => ["Link the Figma design."]}
      assert ws["rig_standing_orders"] == %{"client" => ["Link the Figma design."]}
    end
  end

  # bd-9fgg04: a paused scheduler still draining must not read as idle.
  describe "scheduler section" do
    defp stub_with_scheduler(scheduler_resp) do
      stub_routes([
        {{"get", "/api/scheduler/status"}, scheduler_resp},
        {{"get", "/api/workspaces"}, {%{"data" => []}, 200}},
        {{"get", "/api/messages"}, {%{"data" => []}, 200}}
      ])
    end

    @draining %{
      "state" => "draining",
      "paused" => true,
      "safe_to_restart" => false,
      "in_flight" => [%{"kind" => "fix_pass", "task_id" => "bd-77j2if", "status" => "running"}]
    }

    test "shows the drain state and what is still in flight" do
      stub_with_scheduler({@draining, 200})

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      assert out =~ "== Scheduler =="
      assert out =~ "paused, draining"
      assert out =~ "NOT safe to restart"
      assert out =~ "fix_pass"
      assert out =~ "bd-77j2if"
    end

    test "shows the account-qualified quota hold" do
      reason = "claude:default 7d 20% ≥ paced 20% (20% elapsed)"
      stub_with_scheduler({Map.put(@draining, "quota_hold", reason), 200})

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      assert out =~ "held — #{reason}"
    end

    test "shows no hold line when nothing is held" do
      stub_with_scheduler({@draining, 200})

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      refute out =~ "held —"
    end

    test "--json carries the drain state under scheduler" do
      stub_with_scheduler({@draining, 200})

      {out, _err, 0} = capture(fn -> Prime.run(["--json"]) end)

      assert %{"scheduler" => %{"state" => "draining", "in_flight" => [_]}} =
               Jason.decode!(String.trim(out))
    end

    test "an unreachable scheduler status is marked unavailable, not omitted" do
      stub_with_scheduler({%{"error" => %{"message" => "nope"}}, 500})

      {out, _err, 0} = capture(fn -> Prime.run([]) end)

      assert out =~ "== Scheduler =="
      assert out =~ "unavailable"
    end
  end
end
