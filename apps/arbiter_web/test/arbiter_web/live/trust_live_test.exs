defmodule ArbiterWeb.TrustLiveTest do
  @moduledoc """
  G18 (bd-7i9pxn, `docs/design/guardrail-profiles.md` §6.5): the `/trust`
  dashboard shows each subject's tier, record, recent events and pending
  promotion proposal, from the same `Arbiter.Loop.Trust.View` maps as
  `arb trust show`. It is a view: a promotion is the operator's, from
  `arb trust promote`, and the page offers no control that applies one.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Guardrails.Subjects
  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop
  alias Arbiter.Loop.Trust
  alias ArbiterWeb.TrustLive

  @codex "codex/gpt-5.1-codex"
  @agy "antigravity/gemini-3.8-flash-low"
  @opus "claude/claude-opus-4-6"

  # The list and the selected subject arrive by `start_async/3` on the
  # connected mount, like the `/loop` page.
  @async_timeout 5_000

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "trust-ui-#{n}", prefix: "tu#{n}"})

    {:ok, _} = Subjects.put(%{provider: "codex", tier: :quarantine}, :operator)
    {:ok, _} = Subjects.put(%{provider: "antigravity", tier: :probation}, :operator)
    {:ok, _} = Subjects.put(%{provider: "claude", tier: :privileged}, :operator)

    {:ok, _codex} =
      Ash.create(TrustRecord, %{
        provider: "codex",
        model: "gpt-5.1-codex",
        family: "openai",
        tier: :quarantine,
        runs: 12,
        clean_runs: 11,
        clean_tickets: 8,
        clean_repos: 1,
        minor_events: 1,
        reviewed: 10,
        round1_approve_rate: 0.9,
        harness_version: "0.51.0",
        model_version: "gpt-5.1-codex",
        eligible_for: :probation,
        eligibility: %{
          "from" => "quarantine",
          "to" => "probation",
          "proposed" => true,
          "criteria" => [
            %{"name" => "clean_runs", "need" => 10, "have" => 11, "met" => true},
            %{
              "name" => "round1_quality",
              "met" => true,
              "detail" => "90.0% vs the incumbent's 88.0%"
            }
          ]
        },
        recent_events: [
          %{
            "id" => "ev-1",
            "kind" => "permission_denial",
            "severity" => "minor",
            "source" => "claude_permission",
            "run_id" => "run-1",
            "task_id" => "bd-t1",
            "detail" => "rm -rf denied",
            "at" => "2026-10-01T12:00:00.000000Z"
          }
        ],
        history: [
          %{
            "at" => "2026-10-02T00:00:00.000000Z",
            "action" => "version_changed",
            "actor" => "loop:trust",
            "from" => %{"harness_version" => "0.50.0"},
            "to" => %{"harness_version" => "0.51.0"}
          }
        ]
      })

    {:ok, _agy} =
      Ash.create(TrustRecord, %{
        provider: "antigravity",
        model: "gemini-3.8-flash-low",
        family: "google",
        tier: :probation,
        runs: 4,
        clean_runs: 2,
        critical_events: 1,
        suspended_at: ~U[2026-10-09 12:00:00.000000Z],
        suspension: %{
          "id" => "ev-9",
          "kind" => "public_upload_attempt",
          "severity" => "critical",
          "run_id" => "run-9",
          "task_id" => "bd-t9",
          "detail" => "curl -F file=@notes 0x0.st",
          "prior_tier" => "probation",
          "parked" => ["bd-t9"]
        }
      })

    {:ok, _opus} =
      Ash.create(TrustRecord, %{
        provider: "claude",
        model: "claude-opus-4-6",
        family: "anthropic",
        tier: :privileged,
        runs: 30,
        clean_runs: 27
      })

    {:ok, proposal} =
      Loop.record(
        %{
          kind: :trust_promotion,
          gist: "promote #{@codex} quarantine → probation",
          category: "trust:quarantine->probation",
          target: @codex,
          scope: :fleet,
          incident_refs: ["run-1", "run-2"],
          task_refs: ["bd-t1"],
          payload: %{
            "provider" => "codex",
            "model" => "gpt-5.1-codex",
            "from" => "quarantine",
            "to" => "probation"
          },
          origin: "loop.trust",
          workspace_id: ws.id
        },
        evidence_bar: %{min_incidents: 1, min_distinct_tasks: 1}
      )

    %{ws: ws, proposal: proposal}
  end

  defp live_trust(conn, path \\ ~p"/trust") do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @async_timeout)
    view
  end

  defp row(subject), do: "##{TrustLive.dom_id(subject)}"

  describe "the subject list" do
    test "shows every subject's tier and record", %{conn: conn} do
      view = live_trust(conn)

      assert has_element?(view, "#trust-subjects")

      for subject <- [@codex, @agy, @opus] do
        assert has_element?(view, row(subject), subject)
      end

      assert has_element?(view, row(@codex) <> " [data-role=tier]", "quarantine")
      assert has_element?(view, row(@codex) <> " [data-role=record]", "11/12 clean")
      assert has_element?(view, row(@codex) <> " [data-role=events]", "0/0/1")
      assert has_element?(view, row(@codex) <> " [data-role=round1]", "90.0%")
      assert has_element?(view, row(@opus) <> " [data-role=tier]", "privileged")
    end

    test "flags a pending promotion and a suspension on their rows", %{conn: conn} do
      view = live_trust(conn)

      assert has_element?(
               view,
               row(@codex) <> " [data-role=status]",
               "promotion to probation proposed"
             )

      assert has_element?(view, row(@agy) <> " [data-role=status]", "suspended")
      assert has_element?(view, row(@agy) <> " [data-role=status]", "quarantine")
    end

    test "says so when there is nothing to show", %{conn: conn} do
      # `TrustRecord` has no destroy action: only the Loop writes it.
      Arbiter.Repo.query!("DELETE FROM trust_records")

      view = live_trust(conn)

      assert has_element?(view, "#trust-empty")
      refute has_element?(view, "#trust-subjects")
    end
  end

  describe "one subject" do
    test "selecting it shows its record, recent events, history and pending proposal", %{
      conn: conn,
      proposal: proposal
    } do
      view = live_trust(conn)

      view |> element(row(@codex) <> " [data-role=open]") |> render_click()
      assert_patch(view, ~p"/trust?#{[subject: @codex]}")
      render_async(view, @async_timeout)

      assert has_element?(view, "#trust-detail", @codex)
      assert has_element?(view, "#trust-versions", "0.51.0")
      assert has_element?(view, "#trust-eligibility", "clean_runs")
      assert has_element?(view, "#trust-eligibility", "90.0% vs the incumbent's 88.0%")
      assert has_element?(view, "#trust-recent-events", "permission_denial")
      assert has_element?(view, "#trust-recent-events", "rm -rf denied")
      assert has_element?(view, "#trust-history", "version_changed")

      assert has_element?(view, "#trust-pending", proposal.id)

      assert has_element?(
               view,
               "#trust-pending",
               ~s(arb trust promote #{@codex} --to probation --reason "...")
             )
    end

    test "a suspended subject shows the event and the coordinator's two commands", %{conn: conn} do
      view = live_trust(conn, ~p"/trust?#{[subject: @agy]}")

      assert has_element?(view, "#trust-suspension", "public_upload_attempt")
      assert has_element?(view, "#trust-suspension", "bd-t9")
      assert has_element?(view, "#trust-suspension", "arb trust confirm #{@agy}")
      assert has_element?(view, "#trust-suspension", ~s(arb trust dismiss #{@agy} --reason "..."))
    end

    test "an unknown subject in the address says so", %{conn: conn} do
      view = live_trust(conn, ~p"/trust?#{[subject: "codex/nope"]}")

      assert has_element?(view, "#trust-detail-missing", "codex/nope")
      assert has_element?(view, "#trust-subjects")
    end

    test "closing it goes back to the list alone", %{conn: conn} do
      view = live_trust(conn, ~p"/trust?#{[subject: @codex]}")
      assert has_element?(view, "#trust-detail")

      view |> element("#trust-detail-close") |> render_click()
      assert_patch(view, ~p"/trust")

      refute has_element?(view, "#trust-detail")
    end
  end

  describe "a view, never a control" do
    test "offers nothing that promotes, confirms or dismisses", %{conn: conn} do
      view = live_trust(conn, ~p"/trust?#{[subject: @codex]}")

      refute has_element?(view, "#trust-page form")
      refute has_element?(view, "#trust-page [phx-click=promote]")
      refute has_element?(view, "#trust-page [phx-click=apply]")
      refute has_element?(view, "#trust-page [phx-click=confirm]")
      refute has_element?(view, "#trust-page [phx-click=dismiss]")
    end
  end

  describe "live updates" do
    test "a change to the trust records re-renders the page", %{conn: conn} do
      view = live_trust(conn, ~p"/trust?#{[subject: @codex]}")
      refute has_element?(view, row(@codex) <> " [data-role=tier]", "probation")

      {:ok, _} = Subjects.put(%{provider: "codex", tier: :probation}, :operator)
      record = Trust.get(@codex)
      {:ok, _} = Ash.update(record, %{tier: :probation, eligible_for: nil})

      Phoenix.PubSub.broadcast(Arbiter.PubSub, Trust.pubsub_topic(), {:trust, :updated})
      _ = :sys.get_state(view.pid)
      render_async(view, @async_timeout)

      assert has_element?(view, row(@codex) <> " [data-role=tier]", "probation")
    end
  end
end
