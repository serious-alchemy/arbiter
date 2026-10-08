defmodule ArbiterWeb.Api.MessageControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message

  # `workspace` is resolved server-side (id or name; unknown is a 404), so the
  # fixtures hang off real workspaces.
  setup %{conn: conn} do
    ws = Ash.create!(Workspace, %{name: "ws-api-msg-#{System.unique_integer([:positive])}"})
    Ash.create!(Workspace, %{name: "ws-api-msg-other-#{System.unique_integer([:positive])}"})
    Process.put(:msg_ws, ws.id)
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp ws_id, do: Process.get(:msg_ws)

  describe "POST /api/messages" do
    test "creates a mailbox message", %{conn: conn} do
      task = Ash.create!(Issue, %{title: "recipient", workspace_id: ws_id(), acceptance: "- x"})

      conn =
        post(conn, ~p"/api/messages", %{
          kind: "mailbox",
          from_ref: "coordinator",
          to_ref: task.id,
          subject: "heads up",
          body: "check the API contract",
          workspace_id: ws_id()
        })

      body = json_response(conn, 201)
      assert body["kind"] == "mailbox"
      assert body["to_ref"] == task.id
      assert body["body"] == "check the API contract"
      assert body["read_at"] == nil
    end

    test "returns 422 on missing workspace_id", %{conn: conn} do
      conn = post(conn, ~p"/api/messages", %{kind: "notification", body: "x"})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "returns 422 on invalid kind", %{conn: conn} do
      conn = post(conn, ~p"/api/messages", %{kind: "bogus", body: "x", workspace_id: ws_id()})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "accepts a coordinator-bound completion with a directive_ref", %{conn: conn} do
      conn =
        post(conn, ~p"/api/messages", %{
          kind: "completion",
          from_ref: "bd-soren",
          to_ref: "coordinator",
          directive_ref: "bd-soren",
          body: "GitLab adapter complete",
          workspace_id: ws_id()
        })

      body = json_response(conn, 201)
      assert body["kind"] == "completion"
      assert body["to_ref"] == "coordinator"
      assert body["directive_ref"] == "bd-soren"
    end
  end

  # bd-2nbu7a / #15: `arb` defaults to http://127.0.0.1:4848, so an agent CLI
  # running in a throwaway sandbox on this host (a test fixture, a nested
  # install) posts to the live coordinator. Its escalation names a task this
  # installation has never heard of; it is delivered, but marked.
  describe "POST /api/messages escalation origin" do
    @wording "the task worktree and its entire provider root (/tmp/rev-provider-57795) " <>
               "were deleted mid-session; arbiter MCP is ConnectionRefused"

    defp post_escalation(conn, task_ref) do
      post(conn, ~p"/api/messages", %{
        kind: "escalation",
        from_ref: task_ref,
        to_ref: "coordinator",
        task_ref: task_ref,
        subject: "CI fix-pass on #{task_ref} needs human review",
        body: @wording,
        workspace_id: ws_id()
      })
    end

    test "an escalation about a task this installation does not know is marked", %{conn: conn} do
      body = json_response(post_escalation(conn, "fp-6u0wu1"), 201)

      assert body["subject"] =~ "[UNVERIFIED ORIGIN"
      assert body["subject"] =~ "fp-6u0wu1"
      assert body["body"] =~ "not a task in this installation"
      # Marked, never dropped: the original wording is still there to read.
      assert body["body"] =~ "ConnectionRefused"
    end

    test "a genuine escalation about a real task with the same wording is delivered unmarked",
         %{conn: conn} do
      {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "origin-ws", prefix: "orw"})
      {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "real work", workspace_id: ws.id})

      body = json_response(post_escalation(conn, task.id), 201)

      refute body["subject"] =~ "UNVERIFIED"
      refute body["body"] =~ "not a task in this installation"
      assert body["subject"] == "CI fix-pass on #{task.id} needs human review"
      assert body["body"] == @wording
    end

    test "an escalation with no task_ref is not marked", %{conn: conn} do
      conn =
        post(conn, ~p"/api/messages", %{
          kind: "escalation",
          to_ref: "coordinator",
          subject: "operator note",
          body: "hi",
          workspace_id: ws_id()
        })

      refute json_response(conn, 201)["subject"] =~ "UNVERIFIED"
    end
  end

  describe "GET /api/messages" do
    test "lists messages, filtering by kind and to_ref", %{conn: conn} do
      {:ok, _} = Message.notify(%{workspace_id: ws_id(), body: "a notification"})
      {:ok, _} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-1", body: "for bd-1"})
      {:ok, _} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-2", body: "for bd-2"})

      conn = get(conn, ~p"/api/messages", %{kind: "notification"})
      data = json_response(conn, 200)["data"]
      assert Enum.all?(data, &(&1["kind"] == "notification"))

      conn = get(coordinator_conn(), ~p"/api/messages", %{to_ref: "bd-1"})
      data = json_response(conn, 200)["data"]
      assert [%{"body" => "for bd-1"}] = data
    end

    test "unread=true returns only unacknowledged messages", %{conn: conn} do
      {:ok, m} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-u", body: "unread one"})
      {:ok, read} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-u", body: "read one"})
      {:ok, _} = Message.mark_read(read)

      conn = get(conn, ~p"/api/messages", %{to_ref: "bd-u", unread: "true"})
      data = json_response(conn, 200)["data"]
      assert [%{"id" => id}] = data
      assert id == m.id
    end

    test "unread=true excludes a message that was soft-cleared while still unread",
         %{conn: conn} do
      {:ok, pending} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-c", body: "pending"})

      {:ok, cleared_unread} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-c", body: "cleared-unread"})

      # Soft-clear only the second one *while it is still unread* (read_at nil,
      # cleared_at set) — the state clear_all can produce for never-seen mail.
      {:ok, _} = Message.mark_cleared(cleared_unread)

      conn = get(conn, ~p"/api/messages", %{to_ref: "bd-c", unread: "true"})
      data = json_response(conn, 200)["data"]
      ids = Enum.map(data, & &1["id"]) |> MapSet.new()
      # Only the never-cleared pending row shows; the cleared-unread one does not.
      assert ids == MapSet.new([pending.id])
    end

    test "outstanding=true returns read-but-uncleared messages and exposes cleared_at",
         %{conn: conn} do
      {:ok, _pending} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-o", body: "pending"})

      {:ok, out} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-o", body: "outstanding"})

      {:ok, done} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-o", body: "cleared"})
      {:ok, _} = Message.mark_read(out)
      {:ok, _} = Message.mark_read(done)
      {:ok, _} = Message.mark_cleared(done)

      conn = get(conn, ~p"/api/messages", %{to_ref: "bd-o", outstanding: "true"})
      data = json_response(conn, 200)["data"]
      assert [%{"id" => id, "cleared_at" => nil} = row] = data
      assert id == out.id
      refute is_nil(row["read_at"])
    end

    test "rejects a bad limit", %{conn: conn} do
      conn = get(conn, ~p"/api/messages", %{limit: "abc"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "POST /api/messages/:id/read" do
    test "stamps read_at", %{conn: conn} do
      {:ok, m} = Message.send_mail(%{workspace_id: ws_id(), to_ref: "bd-r", body: "mark me"})

      conn = post(conn, ~p"/api/messages/#{m.id}/read", %{})
      body = json_response(conn, 200)
      refute is_nil(body["read_at"])
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = post(conn, ~p"/api/messages/00000000-0000-0000-0000-000000000000/read", %{})
      assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/messages (soft clear)" do
    test "soft-clears only the outstanding messages addressed to to_ref; rows retained",
         %{conn: conn} do
      {:ok, unread} =
        Message.send_mail(%{
          workspace_id: ws_id(),
          to_ref: "coordinator",
          kind: :info,
          body: "keep me"
        })

      {:ok, read} =
        Message.send_mail(%{
          workspace_id: ws_id(),
          to_ref: "coordinator",
          kind: :info,
          body: "clear me"
        })

      {:ok, _} = Message.mark_read(read)

      {:ok, other} =
        Message.send_mail(%{
          workspace_id: ws_id(),
          to_ref: "bd-other",
          kind: :info,
          body: "not coordinator's"
        })

      {:ok, _} = Message.mark_read(other)

      conn = delete(conn, ~p"/api/messages", %{to_ref: "coordinator"})

      assert %{"data" => %{"deleted_read" => 1, "deleted_unread" => 0, "remaining_unread" => 1}} =
               json_response(conn, 200)

      # NOTHING is destroyed — clear is soft. The read coordinator message is
      # retained with cleared_at stamped; unread and the other task are untouched.
      assert {:ok, %Message{cleared_at: cleared_at}} = Ash.get(Message, read.id)
      assert cleared_at
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, unread.id)
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, other.id)
    end

    test "all=true soft-clears both read and unread messages addressed to to_ref",
         %{conn: conn} do
      {:ok, unread} =
        Message.send_mail(%{
          workspace_id: ws_id(),
          to_ref: "coordinator",
          kind: :info,
          body: "unread"
        })

      {:ok, read} =
        Message.send_mail(%{
          workspace_id: ws_id(),
          to_ref: "coordinator",
          kind: :info,
          body: "read"
        })

      {:ok, _} = Message.mark_read(read)

      conn = delete(conn, ~p"/api/messages", %{to_ref: "coordinator", all: "true"})

      assert %{"data" => %{"deleted_read" => 1, "deleted_unread" => 1, "remaining_unread" => 0}} =
               json_response(conn, 200)

      # Both retained (soft), both cleared.
      assert {:ok, %Message{cleared_at: c1}} = Ash.get(Message, read.id)
      assert {:ok, %Message{cleared_at: c2}} = Ash.get(Message, unread.id)
      assert c1
      assert c2
    end

    test "requires to_ref so it can't wipe the table", %{conn: conn} do
      conn = delete(conn, ~p"/api/messages", %{})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  # ---- bd-8akewg: explicit reader ------------------------------------------

  describe "per-reader read state" do
    setup do
      ws =
        Ash.create!(Workspace, %{name: "ws-api-reader-#{System.unique_integer([:positive])}"}).id

      {:ok, m} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws,
          to_ref: "coordinator",
          body: "shared escalation"
        })

      %{ws: ws, message: m, session: "sess-#{System.unique_integer([:positive])}"}
    end

    test "read with `session` marks it read for that session only", ctx do
      %{conn: conn, message: m, session: session} = ctx

      conn = post(conn, ~p"/api/messages/#{m.id}/read", %{session: session})
      assert json_response(conn, 200)

      # The shared row is untouched, so the sessionless coordinator still has it.
      {:ok, reloaded} = Ash.get(Message, m.id)
      assert reloaded.read_at == nil

      reader = Message.session_reader(session)
      assert [] = Message.inbox("coordinator", workspace_id: ctx.ws, reader: reader)
      assert [_] = Message.outstanding("coordinator", workspace_id: ctx.ws, reader: reader)
    end

    test "read without `session` keeps stamping the row (sessionless coordinator)", ctx do
      %{conn: conn, message: m} = ctx

      conn = post(conn, ~p"/api/messages/#{m.id}/read", %{})
      assert json_response(conn, 200)["read_at"]

      {:ok, reloaded} = Ash.get(Message, m.id)
      assert reloaded.read_at
    end

    test "clear with `session` clears only that session's view", ctx do
      %{conn: conn, message: m, session: session} = ctx
      reader = Message.session_reader(session)

      {:ok, _} = Message.mark_read(m, reader: reader)

      conn = delete(conn, ~p"/api/messages", %{to_ref: "coordinator", session: session})
      assert %{"deleted_read" => 1} = json_response(conn, 200)["data"]

      {:ok, reloaded} = Ash.get(Message, m.id)
      assert reloaded.cleared_at == nil
      assert [] = Message.outstanding("coordinator", workspace_id: ctx.ws, reader: reader)
      assert [_] = Message.inbox("coordinator", workspace_id: ctx.ws)
    end

    test "clear by ids with `session` clears only that session's view", ctx do
      %{conn: conn, message: m, session: session} = ctx
      reader = Message.session_reader(session)

      {:ok, _} = Message.mark_read(m, reader: reader)

      conn = delete(conn, ~p"/api/messages", %{ids: m.id, session: session})
      assert %{"cleared" => [id], "not_found" => []} = json_response(conn, 200)["data"]
      assert id == m.id

      {:ok, reloaded} = Ash.get(Message, m.id)
      assert reloaded.cleared_at == nil
      assert [] = Message.outstanding("coordinator", workspace_id: ctx.ws, reader: reader)
      assert [_] = Message.inbox("coordinator", workspace_id: ctx.ws)
    end

    test "clear by task_id with `session` clears only that session's view", ctx do
      %{conn: conn, session: session, ws: ws} = ctx
      reader = Message.session_reader(session)
      task = "bd-api#{System.unique_integer([:positive])}"

      {:ok, m} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws,
          to_ref: "coordinator",
          task_ref: task,
          body: "task escalation"
        })

      conn =
        delete(conn, ~p"/api/messages", %{task_id: task, session: session, workspace_id: ws})

      assert %{"cleared_count" => 1} = json_response(conn, 200)["data"]

      {:ok, reloaded} = Ash.get(Message, m.id)
      assert reloaded.cleared_at == nil
      assert Enum.any?(Message.inbox("coordinator", workspace_id: ws), &(&1.id == m.id))

      refute Enum.any?(
               Message.inbox("coordinator", workspace_id: ws, reader: reader),
               &(&1.id == m.id)
             )
    end

    test "index mark_read=true without to_ref is refused and consumes nothing", ctx do
      %{conn: conn, message: m} = ctx

      body =
        conn
        |> get(~p"/api/messages", %{unread: "true", mark_read: "true"})
        |> json_response(400)

      assert inspect(body) =~ "mark_read requires to_ref"

      listed =
        conn
        |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true"})
        |> json_response(200)

      assert m.id in Enum.map(listed["data"], & &1["id"])
    end

    test "index unread=true with `session` is that session's unread view", ctx do
      %{conn: conn, message: m, session: session} = ctx

      listed =
        conn
        |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true", session: session})
        |> json_response(200)

      assert m.id in Enum.map(listed["data"], & &1["id"])

      {:ok, _} = Message.mark_read(m, reader: Message.session_reader(session))

      listed =
        conn
        |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true", session: session})
        |> json_response(200)

      refute m.id in Enum.map(listed["data"], & &1["id"])

      # …and the sessionless view is unaffected.
      listed =
        conn
        |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true"})
        |> json_response(200)

      assert m.id in Enum.map(listed["data"], & &1["id"])
    end

    test "a real session's unread view over REST matches coordinator_inbox's bound", %{conn: conn} do
      # bd-8akewg review finding 2: `arb inbox --session <id>` lands here, while
      # the MCP `coordinator_inbox` lands in Tools.Messaging. Both resolve the
      # session's unread bound through `Message.unread_floor/2`, so the archive
      # must drop out here too rather than printing "50 unread" of long-resolved
      # mail for a session the MCP tool reports 0 for.
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "api-floor-#{System.unique_integer([:positive])}",
          prefix: "afl"
        })

      {:ok, archived} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws.id,
          to_ref: "coordinator",
          body: "resolved long ago"
        })

      {:ok, _} = Message.mark_read(archived, reader: Message.coordinator_reader())
      {:ok, _} = Message.mark_cleared(archived)

      {:ok, unresolved} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws.id,
          to_ref: "coordinator",
          body: "still owed"
        })

      {:ok, session} =
        Ash.create(Arbiter.Sessions.Session, %{cwd: "/tmp/api-floor", workspace_id: ws.id})

      ids =
        conn
        |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true", session: session.id})
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert unresolved.id in ids
      refute archived.id in ids

      # …exactly the set the MCP handler reports for the same session.
      assert [%{id: mcp_id}] =
               Message.inbox("coordinator",
                 workspace_id: ws.id,
                 reader: Message.session_reader(session.id)
               )

      assert mcp_id == unresolved.id
    end
  end

  describe "DELETE /api/messages?ids=... (per-message soft clear)" do
    test "soft-clears exactly the given ids, resolved regardless of workspace", %{conn: conn} do
      {:ok, m1} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "coordinator", kind: :info, body: "1"})

      {:ok, m2} =
        Message.send_mail(%{
          workspace_id: "ws-elsewhere",
          to_ref: "coordinator",
          kind: :info,
          body: "2"
        })

      {:ok, untouched} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "coordinator", kind: :info, body: "3"})

      conn = delete(conn, ~p"/api/messages", %{ids: "#{m1.id},#{m2.id}"})

      assert %{"data" => %{"cleared" => cleared, "not_found" => []}} =
               json_response(conn, 200)

      assert Enum.sort(cleared) == Enum.sort([m1.id, m2.id])
      assert {:ok, %Message{cleared_at: c1}} = Ash.get(Message, m1.id)
      assert {:ok, %Message{cleared_at: c2}} = Ash.get(Message, m2.id)
      assert c1
      assert c2
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, untouched.id)
    end

    test "reports unknown ids as not_found", %{conn: conn} do
      {:ok, m} =
        Message.send_mail(%{workspace_id: ws_id(), to_ref: "coordinator", kind: :info, body: "1"})

      bogus = Ecto.UUID.generate()

      conn = delete(conn, ~p"/api/messages", %{ids: "#{m.id},#{bogus}"})

      assert %{"data" => %{"cleared" => [cleared_id], "not_found" => [^bogus]}} =
               json_response(conn, 200)

      assert cleared_id == m.id
    end
  end

  describe "DELETE /api/messages?task_id=... (per-task soft clear)" do
    test "clears every coordinator message concerning the task", %{conn: conn} do
      task = "bd-ctrl-cleartask"

      {:ok, escalation} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws_id(),
          to_ref: "coordinator",
          task_ref: task,
          body: "needs a decision"
        })

      {:ok, unrelated} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws_id(),
          to_ref: "coordinator",
          task_ref: "bd-ctrl-other",
          body: "not this task"
        })

      conn = delete(conn, ~p"/api/messages", %{task_id: task, workspace_id: ws_id()})

      assert %{"data" => %{"cleared" => [cleared_id], "cleared_count" => 1}} =
               json_response(conn, 200)

      assert cleared_id == escalation.id
      assert {:ok, %Message{cleared_at: cleared_at}} = Ash.get(Message, escalation.id)
      assert cleared_at
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, unrelated.id)
    end

    # P-26 (D-M-3): a task id is unambiguous, so naming no workspace clears the
    # thread everywhere — the same as MCP `coordinator_inbox_clear`.
    test "with several workspaces and none named it clears the thread in all of them",
         %{conn: conn} do
      task = "bd-ctrl-cleartask-ambiguous"

      {:ok, msg} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: ws_id(),
          to_ref: "coordinator",
          task_ref: task,
          body: "needs a decision"
        })

      conn = delete(conn, ~p"/api/messages", %{task_id: task})

      assert %{"data" => %{"cleared" => [id], "cleared_count" => 1}} = json_response(conn, 200)
      assert id == msg.id
      assert {:ok, %Message{cleared_at: %DateTime{}}} = Ash.get(Message, msg.id)
    end

    test "scopes to a workspace when given", %{conn: conn} do
      task = "bd-ctrl-cleartask-ws"
      elsewhere_ws = Ash.create!(Workspace, %{name: "ws-elsewhere-2"})

      {:ok, elsewhere} =
        Message.send_mail(%{
          kind: :escalation,
          escalation_kind: :agent_raised,
          workspace_id: elsewhere_ws.id,
          to_ref: "coordinator",
          task_ref: task,
          body: "elsewhere"
        })

      conn = delete(conn, ~p"/api/messages", %{task_id: task, workspace_id: ws_id()})

      assert %{"data" => %{"cleared" => [], "cleared_count" => 0}} = json_response(conn, 200)
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, elsewhere.id)
    end
  end

  describe "P-26 mailbox parity" do
    setup do
      other =
        Ash.create!(Workspace, %{name: "ws-p26-recipient-#{System.unique_integer([:positive])}"})

      task = Ash.create!(Issue, %{title: "T", workspace_id: other.id, acceptance: "- x"})
      {:ok, other: other, task: task}
    end

    test "a send is filed under the RECIPIENT task's workspace and the task's own mailbox sees it",
         %{conn: conn, task: task, other: other} do
      # No workspace named: the CLI default workspace must not be stamped on it.
      body =
        conn
        |> post(~p"/api/messages", %{to_ref: task.id, body: "go", kind: "info"})
        |> json_response(201)

      assert body["workspace_id"] == other.id

      worker =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> Scope.mint_worker(%{id: task.id, workspace_id: other.id})
        )

      assert %{"data" => [%{"id" => id}]} =
               worker
               |> get(~p"/api/messages", %{to_ref: task.id, unread: "true", mark_read: "true"})
               |> json_response(200)

      assert id == body["id"]

      assert %{"data" => []} =
               worker
               |> get(~p"/api/messages", %{to_ref: task.id, unread: "true"})
               |> json_response(200)
    end

    test "a workspace that is not the recipient's is refused", %{conn: conn, task: task} do
      assert %{"error" => %{"type" => "validation_error"}} =
               conn
               |> post(~p"/api/messages", %{to_ref: task.id, body: "go", workspace_id: ws_id()})
               |> json_response(422)
    end

    test "a recipient that is not a task (a typo'd verb) is a 404, not a filed message",
         %{conn: conn} do
      assert conn
             |> post(~p"/api/messages", %{to_ref: "sned", body: "bd-1 hi", kind: "direction"})
             |> json_response(404)

      assert [] = Message |> Ash.read!() |> Enum.filter(&(&1.to_ref == "sned"))
    end

    test "GET honours workspace_id", %{conn: conn, task: task, other: other} do
      Message.send_mail(%{
        kind: :info,
        workspace_id: ws_id(),
        to_ref: "coordinator",
        body: "mine"
      })

      Message.send_mail(%{
        kind: :info,
        workspace_id: other.id,
        to_ref: "coordinator",
        body: "theirs"
      })

      _ = task

      assert %{"data" => [%{"body" => "theirs"}]} =
               conn
               |> get(~p"/api/messages", %{to_ref: "coordinator", workspace_id: other.id})
               |> json_response(200)
    end

    test "a plain GET never marks read; the queue is oldest-first and uncapped", %{conn: conn} do
      for i <- 1..3 do
        Message.send_mail(%{
          kind: :info,
          workspace_id: ws_id(),
          to_ref: "coordinator",
          body: "q#{i}"
        })
      end

      params = %{to_ref: "coordinator", unread: "true", workspace_id: ws_id()}
      assert %{"data" => list} = conn |> get(~p"/api/messages", params) |> json_response(200)
      assert Enum.map(list, & &1["body"]) == ["q1", "q2", "q3"]
      assert %{"data" => [_, _, _]} = conn |> get(~p"/api/messages", params) |> json_response(200)
    end

    test "unread and outstanding together is a 400", %{conn: conn} do
      assert conn
             |> get(~p"/api/messages", %{unread: "true", outstanding: "true"})
             |> json_response(400)
    end

    test "a worker token can read the notification feed, confined to its workspace",
         %{conn: conn, task: task, other: other} do
      Message.notify(%{kind: :notification, workspace_id: other.id, from_ref: "w", body: "in"})
      Message.notify(%{kind: :notification, workspace_id: ws_id(), from_ref: "w", body: "out"})

      worker =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> Scope.mint_worker(%{id: task.id, workspace_id: other.id})
        )

      assert %{"data" => [%{"body" => "in"}]} =
               worker |> get(~p"/api/messages", %{kind: "notification"}) |> json_response(200)

      # Anything else on the coordinator side stays refused.
      assert worker |> get(~p"/api/messages", %{to_ref: "coordinator"}) |> json_response(403)
    end

    test "reader identity comes from the token's session, not only the session param",
         %{conn: conn} do
      {:ok, m} =
        Message.send_mail(%{
          kind: :info,
          workspace_id: ws_id(),
          to_ref: "coordinator",
          body: "shared"
        })

      session = Ash.create!(Arbiter.Sessions.Session, %{cwd: "/tmp/p26", workspace_id: ws_id()})

      session_conn =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> Arbiter.Sessions.Provisioning.mint_token(session)
        )

      # The session token clears its own view only…
      assert %{"data" => %{"cleared" => [_]}} =
               session_conn |> delete(~p"/api/messages", %{ids: m.id}) |> json_response(200)

      # …so the row and the sessionless coordinator still owe the message.
      assert {:ok, %Message{cleared_at: nil}} = Ash.get(Message, m.id)

      assert %{"data" => [_]} =
               conn
               |> get(~p"/api/messages", %{to_ref: "coordinator", unread: "true"})
               |> json_response(200)
    end

    test "every clear form answers with the same keys", %{conn: conn} do
      {:ok, m} =
        Message.send_mail(%{kind: :info, workspace_id: ws_id(), to_ref: "coordinator", body: "x"})

      keys = ~w(cleared cleared_count not_found deleted_read deleted_unread remaining_unread)

      for params <- [%{ids: m.id}, %{task_id: "bd-none"}, %{to_ref: "coordinator"}] do
        assert %{"data" => data} = conn |> delete(~p"/api/messages", params) |> json_response(200)
        assert Enum.all?(keys, &Map.has_key?(data, &1)), inspect({params, data})
      end
    end
  end
end
