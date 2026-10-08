defmodule Arbiter.Messages.MailboxTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Mailbox
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws_a} = Ash.create(Workspace, %{name: "mbx-a-#{n}", prefix: "ma#{n}"})
    {:ok, ws_b} = Ash.create(Workspace, %{name: "mbx-b-#{n}", prefix: "mb#{n}"})

    {:ok, task_a} =
      Ash.create(Issue, %{title: "task in A", workspace_id: ws_a.id, acceptance: "- x"})

    {:ok, task_b} =
      Ash.create(Issue, %{title: "task in B", workspace_id: ws_b.id, acceptance: "- x"})

    coordinator = %Scope{tier: :coordinator}
    worker_b = %Scope{tier: :worker, workspace_id: ws_b.id, task_id: task_b.id}

    {:ok,
     ws_a: ws_a,
     ws_b: ws_b,
     task_a: task_a,
     task_b: task_b,
     coordinator: coordinator,
     worker_b: worker_b}
  end

  describe "reader/2" do
    test "a session token's own session wins; otherwise the explicit session; else the shared reader" do
      assert Mailbox.reader(%Scope{tier: :coordinator, session_id: "s1"}, nil) ==
               Message.session_reader("s1")

      assert Mailbox.reader(%Scope{tier: :coordinator, session_id: "s1"}, "s2") ==
               Message.session_reader("s1")

      assert Mailbox.reader(%Scope{tier: :coordinator}, "s2") == Message.session_reader("s2")
      assert Mailbox.reader(nil, nil) == Message.coordinator_reader()
      assert Mailbox.reader(%Scope{tier: :coordinator}, "") == Message.coordinator_reader()
    end
  end

  describe "send_message/2 workspace" do
    test "a coordinator send files under the RECIPIENT task's workspace, whatever workspace is named",
         ctx do
      assert {:ok, msg} =
               Mailbox.send_message(ctx.coordinator, %{
                 to_ref: ctx.task_b.id,
                 body: "go",
                 kind: :info
               })

      assert msg.workspace_id == ctx.ws_b.id
      assert msg.task_ref == ctx.task_b.id
      assert msg.from_ref == "coordinator"
    end

    test "a named workspace that disagrees with the recipient's is refused", ctx do
      assert {:error, {:invalid, reason}} =
               Mailbox.send_message(ctx.coordinator, %{
                 to_ref: ctx.task_b.id,
                 body: "go",
                 workspace: ctx.ws_a.id
               })

      assert reason =~ "recipient"
    end

    test "an unknown recipient is refused instead of filed under a typo'd mailbox", ctx do
      assert {:error, {:not_found, _}} =
               Mailbox.send_message(ctx.coordinator, %{to_ref: "sned", body: "bd-1 hi"})
    end

    test "a coordinator send defaults to a direction; a worker's to a flag", ctx do
      {:ok, dir} = Mailbox.send_message(ctx.coordinator, %{to_ref: ctx.task_a.id, body: "x"})
      assert dir.kind == :direction

      {:ok, flag} =
        Mailbox.send_message(ctx.worker_b, %{to_ref: ctx.task_b.id, body: "x", kind: :direction})

      assert flag.kind == :flag
      assert flag.from_ref == ctx.task_b.id
    end

    test "a worker cannot reach a task in another workspace", ctx do
      assert {:error, {:not_found, _}} =
               Mailbox.send_message(ctx.worker_b, %{to_ref: ctx.task_a.id, body: "x"})
    end

    test "a worker may flag the coordinator, filed in its own workspace and about its own task",
         ctx do
      assert {:ok, msg} =
               Mailbox.send_message(ctx.worker_b, %{
                 to_ref: "coordinator",
                 body: "stuck",
                 kind: :escalation
               })

      assert msg.workspace_id == ctx.ws_b.id
      assert msg.task_ref == ctx.task_b.id
    end
  end

  describe "list/1" do
    test "unread and outstanding are oldest-first and uncapped; history is newest-first and capped",
         ctx do
      for i <- 1..3 do
        {:ok, _} =
          Message.send_mail(%{
            kind: :info,
            workspace_id: ctx.ws_a.id,
            from_ref: "w",
            to_ref: "coordinator",
            body: "m#{i}"
          })
      end

      unread = Mailbox.list(to_ref: "coordinator", state: :unread, workspace_id: ctx.ws_a.id)
      assert Enum.map(unread, & &1.body) == ["m1", "m2", "m3"]

      history = Mailbox.list(to_ref: "coordinator", workspace_id: ctx.ws_a.id, limit: 2)
      assert Enum.map(history, & &1.body) == ["m3", "m2"]
    end

    test "mark_read is explicit: off by default, on when asked", ctx do
      {:ok, _} =
        Message.send_mail(%{
          kind: :direction,
          workspace_id: ctx.ws_a.id,
          from_ref: "coordinator",
          to_ref: ctx.task_a.id,
          body: "d"
        })

      opts = [to_ref: ctx.task_a.id, state: :unread, workspace_id: ctx.ws_a.id]
      assert [_] = Mailbox.list(opts)
      assert [_] = Mailbox.list(opts)
      assert [_] = Mailbox.list(opts ++ [mark_read: true])
      assert [] = Mailbox.list(opts)

      assert [%{read_at: %DateTime{}}] =
               Mailbox.list(
                 to_ref: ctx.task_a.id,
                 state: :outstanding,
                 workspace_id: ctx.ws_a.id
               )
    end

    test "workspace_id scopes the listing", ctx do
      for ws <- [ctx.ws_a, ctx.ws_b] do
        {:ok, _} =
          Message.send_mail(%{
            kind: :info,
            workspace_id: ws.id,
            from_ref: "w",
            to_ref: "coordinator",
            body: ws.name
          })
      end

      assert [%{workspace_id: ws_id}] =
               Mailbox.list(to_ref: "coordinator", state: :unread, workspace_id: ctx.ws_b.id)

      assert ws_id == ctx.ws_b.id
    end

    test "a session reader's read state leaves another reader's view alone", ctx do
      {:ok, _} =
        Message.send_mail(%{
          kind: :info,
          workspace_id: ctx.ws_a.id,
          from_ref: "w",
          to_ref: "coordinator",
          body: "shared"
        })

      a = Message.session_reader(Ash.UUID.generate())
      b = Message.session_reader(Ash.UUID.generate())
      opts = [to_ref: "coordinator", state: :unread]

      assert [_] = Mailbox.list(opts ++ [reader: a, mark_read: true])
      assert [] = Mailbox.list(opts ++ [reader: a])
      assert [_] = Mailbox.list(opts ++ [reader: b])
    end
  end

  describe "clear/2" do
    test "every form returns the same keys", ctx do
      {:ok, m} =
        Message.send_mail(%{
          kind: :failure,
          workspace_id: ctx.ws_a.id,
          from_ref: "w",
          to_ref: "coordinator",
          task_ref: ctx.task_a.id,
          body: "e"
        })

      keys = ~w(cleared cleared_count not_found deleted_read deleted_unread remaining_unread)a

      {:ok, by_ids} = Mailbox.clear({:ids, [m.id, "nope"]}, [])
      assert Enum.all?(keys, &Map.has_key?(by_ids, &1))
      assert by_ids.cleared == [m.id]
      assert by_ids.not_found == ["nope"]

      {:ok, by_task} = Mailbox.clear({:task, ctx.task_a.id}, [])
      assert Enum.all?(keys, &Map.has_key?(by_task, &1))

      {:ok, bulk} = Mailbox.clear({:mailbox, "coordinator", true}, [])
      assert Enum.all?(keys, &Map.has_key?(bulk, &1))
    end

    test "a task clear with no workspace clears the thread in every workspace", ctx do
      {:ok, _} =
        Message.send_mail(%{
          kind: :failure,
          workspace_id: ctx.ws_b.id,
          from_ref: "w",
          to_ref: "coordinator",
          task_ref: ctx.task_b.id,
          body: "e"
        })

      assert {:ok, %{cleared_count: 1}} = Mailbox.clear({:task, ctx.task_b.id}, [])
    end
  end

  describe "notifications/1" do
    test "newest first, capped, workspace scoped", ctx do
      for ws <- [ctx.ws_a, ctx.ws_b] do
        {:ok, _} =
          Message.notify(%{kind: :notification, workspace_id: ws.id, from_ref: "w", body: "n"})
      end

      assert [%{workspace_id: ws_id}] =
               Mailbox.notifications(workspace_id: ctx.ws_a.id, limit: 5)

      assert ws_id == ctx.ws_a.id
    end
  end
end
