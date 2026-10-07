defmodule Arbiter.MCP.TicketParityTest do
  @moduledoc """
  P-13: the MCP ticket tools read and write the same shapes REST does —
  `ticket_show full:true` carries `history` and `current_run`, `ticket_list`
  filters by `difficulty`, the `ticket_*` write tools return the full ticket
  record (`Arbiter.Tasks.IssueSerializer.data/1`, `summary: true` for the slim
  row), a hand-off returns the ticket, and `tracker_sync` shows a plan's `url`.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueSerializer
  alias Arbiter.Tasks.Workspace

  @gh_viewer "parity-viewer"
  @gh_env_var "ARBITER_MCP_PARITY_TOKEN"

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "par-#{System.unique_integer([:positive])}", prefix: "pa"})

    %{ws: ws, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp call!(scope, tool, args) do
    assert {:ok, data} = Catalog.call(scope, tool, args)
    data
  end

  describe "ticket_show full:true" do
    test "carries history and current_run, as GET /api/issues/:id does", ctx do
      t = ticket(ctx.ws)

      assert {:ok, _} = Ash.update(t, %{title: "renamed"}, action: :update)

      full = call!(ctx.coordinator, "ticket_show", %{"id" => t.id, "full" => true})

      assert [%{at: _, action: _, actor: _, changed: _} | _] = full.history
      assert Enum.any?(full.history, &("title" in &1.changed))
      assert Map.has_key?(full, :current_run)
      assert full.current_run == nil
    end

    test "the slim view stays slim", ctx do
      t = ticket(ctx.ws)
      slim = call!(ctx.coordinator, "ticket_show", %{"id" => t.id})
      refute Map.has_key?(slim, :history)
      refute Map.has_key?(slim, :current_run)
    end
  end

  describe "ticket_list" do
    test "filters by difficulty and rows carry the projection", ctx do
      d1 = ticket(ctx.ws, %{difficulty: 1})
      _d3 = ticket(ctx.ws, %{difficulty: 3})

      data = call!(ctx.coordinator, "ticket_list", %{"difficulty" => 1})

      assert [row] = data.tasks
      assert row.id == d1.id
      assert row.difficulty == 1
      assert row.column == "backlog"
    end
  end

  describe "hold_reason" do
    test "a Ready card the scheduler is holding carries it on ticket_ready and ticket_list",
         ctx do
      t = ctx.ws |> ticket() |> put_state!(:queued)

      # No scheduler runs under test, so every Ready card reads as held.
      assert %{} = holds = Arbiter.Tasks.ReadyHolds.for_workspace(ctx.ws.id)
      reason = Map.fetch!(holds, t.id)

      {:ok, %{tasks: [ready]}} = Tools.task_ready(ctx.coordinator, %{})
      {:ok, %{tasks: [listed]}} = Tools.task_list(ctx.coordinator, %{"column" => "ready"})

      assert ready.id == t.id
      assert ready.hold_reason == reason
      assert listed.id == t.id
      assert listed.hold_reason == reason
    end

    test "a card that is not Ready carries none", ctx do
      _backlog = ticket(ctx.ws)

      {:ok, %{tasks: [row]}} = Tools.task_list(ctx.coordinator, %{})
      refute Map.has_key?(row, :hold_reason)
    end
  end

  describe "ticket_* write tools return the REST IssueJSON shape" do
    test "ticket_update returns the full record", ctx do
      t = ticket(ctx.ws)

      data = call!(ctx.coordinator, "ticket_update", %{"id" => t.id, "notes" => "n1"})

      assert data == t.id |> then(&Ash.get!(Issue, &1)) |> IssueSerializer.data()
      assert data.notes == "n1"
      # The fields the 10-field summary used to hide.
      for key <- [:repo, :tracker_ref, :tracker_type, :target_branch, :pr_ref, :notes] do
        assert Map.has_key?(data, key), "missing #{key}"
      end
    end

    test "summary: true keeps the slim row", ctx do
      t = ticket(ctx.ws)

      data =
        call!(ctx.coordinator, "ticket_update", %{"id" => t.id, "notes" => "n", "summary" => true})

      assert data == IssueSerializer.summary(Ash.get!(Issue, t.id))
      refute Map.has_key?(data, :notes)
    end

    test "ticket_create, ticket_promote and ticket_close return the full record", ctx do
      created =
        call!(ctx.coordinator, "ticket_create", %{"title" => "made", "acceptance" => "- x"})

      assert Map.has_key?(created, :tracker_ref)
      assert Map.has_key?(created, :description)

      promoted = call!(ctx.coordinator, "ticket_promote", %{"id" => created.id})
      assert promoted.state == "queued"
      assert Map.has_key?(promoted, :target_branch)

      closed =
        call!(ctx.coordinator, "ticket_close", %{"id" => created.id, "reason" => "wontfix"})

      assert closed.state == "closed"
      assert Map.has_key?(closed, :pr_ref)
    end

    test "ticket_rank reports where the ticket landed in its band", ctx do
      a = ticket(ctx.ws, %{priority: 2})
      b = ticket(ctx.ws, %{priority: 2})

      data = call!(ctx.coordinator, "ticket_rank", %{"id" => b.id, "top" => true})

      assert data.id == b.id
      assert data.priority_band_position == 0
      assert data.priority_band_size == 2
      assert a.id != b.id
    end

    test "ticket_handoff returns the ticket and its attention, as REST does", ctx do
      t = ctx.ws |> ticket() |> put_state!(:active)
      {:ok, _} = Attention.raise_cause(t.id, :run_crashed, "boom")

      data = call!(ctx.coordinator, "ticket_handoff", %{"id" => t.id, "note" => "needs the key"})

      assert data.id == t.id
      assert data.title == t.title
      assert data.attention_owner == "operator"
      assert data.attention_note == "needs the key"
      assert %{owner: "operator"} = data.attention
    end
  end

  describe "dep_remove of an absent edge" do
    test "is removed: 0 with no error", ctx do
      a = ticket(ctx.ws)
      b = ticket(ctx.ws)

      assert %{removed: 0} =
               call!(ctx.coordinator, "dep_remove", %{
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id
               })

      {:ok, _} = Dependencies.add(a.id, b.id, :depends_on)

      assert %{removed: 1} =
               call!(ctx.coordinator, "dep_remove", %{
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id
               })
    end
  end

  describe "tracker_list_issues / tracker_create_ticket (tracker = none)" do
    test "list reports supported: false with no rows", ctx do
      data = call!(ctx.coordinator, "tracker_list_issues", %{})
      assert data == %{data: [], supported: false}
    end

    test "create refuses a workspace with no tracker", ctx do
      assert {:tool_error, message, "invalid_request"} =
               Catalog.call(ctx.coordinator, "tracker_create_ticket", %{"title" => "x"})

      assert message =~ "no tracker configured"
    end

    test "both resolve the workspace by the P-04 rule: a foreign workspace is refused", ctx do
      {:ok, other} =
        Ash.create(Workspace, %{
          name: "par-o-#{System.unique_integer([:positive])}",
          prefix: "pao"
        })

      worker_scope = %Scope{tier: :coordinator, workspace_id: ctx.ws.id, can_dispatch: false}

      claim =
        Catalog.call(worker_scope, "tracker_claim", %{"ref" => "1", "workspace" => other.id})

      list = Catalog.call(worker_scope, "tracker_list_issues", %{"workspace" => other.id})

      create =
        Catalog.call(worker_scope, "tracker_create_ticket", %{
          "title" => "x",
          "workspace" => other.id
        })

      assert elem(list, 0) == elem(claim, 0)
      assert elem(create, 0) == elem(claim, 0)
    end
  end

  describe "ticket_rank pinned (P-15)" do
    test "pinned: false alone unpins; with a move it pins or unpins", ctx do
      t = ticket(ctx.ws)

      pinned =
        call!(ctx.coordinator, "ticket_rank", %{"id" => t.id, "top" => true, "pinned" => true})

      assert pinned.rank_pinned == true

      unpinned = call!(ctx.coordinator, "ticket_rank", %{"id" => t.id, "pinned" => false})
      assert unpinned.rank_pinned == false
      assert unpinned.rank == pinned.rank
    end

    test "no move form and no pinned is refused", ctx do
      t = ticket(ctx.ws)
      assert {:tool_error, _, _} = Catalog.call(ctx.coordinator, "ticket_rank", %{"id" => t.id})
    end
  end

  describe "tracker_claim / tracker_sync (github)" do
    setup do
      System.put_env(@gh_env_var, "parity-token")

      {:ok, gh} =
        Ash.create(Workspace, %{
          name: "par-gh-#{System.unique_integer([:positive])}",
          prefix: "pgh",
          config: %{
            "tracker" => %{
              "type" => "github",
              "config" => %{
                "owner" => "ryanrborn",
                "repo" => "arbiter",
                "credentials_ref" => "env:#{@gh_env_var}"
              }
            }
          }
        })

      on_exit(fn ->
        Arbiter.Trackers.GitHub.Config.clear()
        System.delete_env(@gh_env_var)
      end)

      %{gh: %Scope{tier: :coordinator, workspace_id: gh.id}}
    end

    defp issue_payload(assignee) do
      %{
        "number" => 43,
        "title" => "Wire up the thing",
        "body" => "Mirror me.",
        "state" => "open",
        "html_url" => "https://github.com/ryanrborn/arbiter/issues/43",
        "assignees" => [%{"login" => assignee}]
      }
    end

    test "tracker_sync shows a non-null url for a planned create", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [issue_payload(@gh_viewer)])
        end
      end)

      data = call!(ctx.gh, "tracker_sync", %{"dry" => true})

      assert [%{action: "create", ref: "43", url: url}] = data.data
      assert url == "https://github.com/ryanrborn/arbiter/issues/43"
      assert data.actions == data.data
      assert data.applied == false
      assert data.count == 1
    end

    test "tracker_list_issues lists open issues in the REST shape", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues"} ->
            Req.Test.json(conn, [issue_payload(@gh_viewer)])
        end
      end)

      data = call!(ctx.gh, "tracker_list_issues", %{})

      assert data.supported == true
      assert [%{ref: "43", title: "Wire up the thing", status: "open", url: url}] = data.data
      assert url =~ "issues/43"
    end

    test "tracker_create_ticket creates upstream and returns ref/url/tracker_type", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"POST", "/repos/ryanrborn/arbiter/issues"} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(Map.put(issue_payload(@gh_viewer), "number", 77))
        end
      end)

      data = call!(ctx.gh, "tracker_create_ticket", %{"title" => "Fresh"})

      assert %{ref: "77", tracker_type: "github", url: url} = data
      assert url =~ "77"
      assert Ash.read!(Issue) |> Enum.filter(&(&1.tracker_ref == "77")) == []
    end

    test "tracker_create_ticket requires a title", ctx do
      assert {:tool_error, message, _} = Catalog.call(ctx.gh, "tracker_create_ticket", %{})
      assert message =~ "title"
    end

    test "tracker_claim: difficulty is range-checked before the tracker is called", ctx do
      # No stub: reaching the tracker would raise.
      assert {:tool_error, message, "invalid_request"} =
               Catalog.call(ctx.gh, "tracker_claim", %{"ref" => "43", "difficulty" => 9})

      assert message =~ "out of range 0..5"
    end

    test "tracker_claim: an issue assigned to someone else is a typed not_assigned", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload("someone-else"))
        end
      end)

      assert {:tool_error, message, "not_assigned"} =
               Catalog.call(ctx.gh, "tracker_claim", %{"ref" => "43"})

      assert message =~ "force=true"
    end

    test "tracker_claim: a prior claim by another installation is a typed already_claimed", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [%{"body" => "Claimed. Arbiter installation: other-host."}])

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(@gh_viewer))
        end
      end)

      assert {:tool_error, _message, "already_claimed"} =
               Catalog.call(ctx.gh, "tracker_claim", %{"ref" => "43"})
    end

    test "tracker_claim returns the REST {status, task} shape", ctx do
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/user"} ->
            Req.Test.json(conn, %{"login" => @gh_viewer})

          {"GET", "/repos/ryanrborn/arbiter/issues/43"} ->
            Req.Test.json(conn, issue_payload(@gh_viewer))

          {"GET", "/repos/ryanrborn/arbiter/issues/43/comments"} ->
            Req.Test.json(conn, [])

          {"POST", _} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        end
      end)

      data = call!(ctx.gh, "tracker_claim", %{"ref" => "43"})
      assert data.status == "created"
      assert data.task.tracker_ref == "43"
      assert Map.has_key?(data.task, :description)
    end
  end

  test "Tools.serialize_ticket/2 is the one place the summary option is read", ctx do
    t = ticket(ctx.ws)
    assert Tools.serialize_ticket(t, %{}) == IssueSerializer.data(t)
    assert Tools.serialize_ticket(t, %{"summary" => true}) == IssueSerializer.summary(t)
  end
end
