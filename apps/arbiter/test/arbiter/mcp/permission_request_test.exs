defmodule Arbiter.MCP.PermissionRequestTest do
  @moduledoc """
  bd-dvqdcc (G15a, `docs/design/guardrail-profiles.md` §5.6): the worker-tier
  `permission_request(permission, reason)` tool. It records a `requested`
  event, raises the `:permission_requested` attention to whoever may grant it,
  and grants nothing.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Guardrails.Events
  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  @guardrails %{
    "bindings" => %{
      "prod_read" => %{"grant_by" => "coordinator", "enforced_read_only" => true},
      "prod_ssh" => %{"grant_by" => "operator", "hosts" => ["prod.internal:22"]},
      "tracker_write" => %{"token_secret" => "gh_worker"},
      "secrets:broker_demo" => %{"env_from_secret" => %{"BROKER_KEY" => "broker_key"}}
    }
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "permreq-#{System.unique_integer([:positive])}",
        prefix: "pr",
        config: %{"guardrails" => @guardrails}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "needs reach", workspace_id: ws.id, repo: "shipyard"})

    task = put_state!(task, :active)
    {:ok, other} = Ash.create(Issue, %{title: "someone else", workspace_id: ws.id})

    run =
      Ash.create!(Run, %{
        task_id: task.id,
        repo: "shipyard",
        workspace_id: ws.id,
        state: :working,
        started_at: DateTime.utc_now()
      })

    %{
      ws: ws,
      task: task,
      other: other,
      run: run,
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id, repo: "shipyard"},
      coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true},
      refine: %Scope{tier: :refine, workspace_id: ws.id, task_id: task.id, issue_id: task.id}
    }
  end

  defp request(scope, args), do: Catalog.call(scope, "permission_request", args)

  defp requested_events(task_id),
    do: task_id |> Permissions.events() |> Enum.filter(&(&1.event == :requested))

  describe "who may call it, and what it accepts" do
    test "is a worker-tier tool only", ctx do
      assert {:rpc_error, _, message} =
               request(ctx.coordinator, %{
                 "id" => ctx.task.id,
                 "permission" => "tracker_write",
                 "reason" => "x"
               })

      assert message =~ "not permitted"

      assert {:rpc_error, _, _} =
               request(ctx.refine, %{"permission" => "tracker_write", "reason" => "x"})

      assert requested_events(ctx.task.id) == []
    end

    test "accepts only the caller's own task", ctx do
      assert {:rpc_error, _, message} =
               request(ctx.worker, %{
                 "id" => ctx.other.id,
                 "permission" => "tracker_write",
                 "reason" => "x"
               })

      assert message =~ "own task"
      assert requested_events(ctx.other.id) == []
      assert requested_events(ctx.task.id) == []
    end

    test "refuses a malformed permission with a typed validation error", ctx do
      for bad <- ["nope", "network:", "secrets", "prod_read:extra", 7, nil, ""] do
        assert {:tool_error, message, "validation_error"} =
                 request(ctx.worker, %{"permission" => bad, "reason" => "need it"}),
               "expected #{inspect(bad)} to be refused"

        assert is_binary(message)
      end

      assert requested_events(ctx.task.id) == []
    end

    test "refuses a permission the workspace has no binding for", ctx do
      assert {:tool_error, message, "validation_error"} =
               request(ctx.worker, %{"permission" => "secrets:unbound", "reason" => "need it"})

      assert message =~ "binding"
      assert requested_events(ctx.task.id) == []
    end

    test "a data class is not requestable", ctx do
      assert {:tool_error, message, "validation_error"} =
               request(ctx.worker, %{"permission" => "phi_data", "reason" => "need it"})

      assert message =~ "data class"
      assert requested_events(ctx.task.id) == []
    end

    test "a reason is required", ctx do
      assert {:tool_error, message, "validation_error"} =
               request(ctx.worker, %{"permission" => "tracker_write", "reason" => "  "})

      assert message =~ "reason"
    end

    test "a network host needs no binding, and is canonicalised", ctx do
      assert {:ok, data} =
               request(ctx.worker, %{
                 "permission" => "network:API.example.com",
                 "reason" => "fetch the fixture"
               })

      assert data.permission == "network:api.example.com:443"
      assert [%{permission: "network:api.example.com:443"}] = requested_events(ctx.task.id)
    end
  end

  describe "recording and routing" do
    test "writes a requested row with the reason, the actor and the run", ctx do
      assert {:ok, _} =
               request(ctx.worker, %{
                 "permission" => "tracker_write",
                 "reason" => "comment on the PR thread"
               })

      assert [event] = requested_events(ctx.task.id)
      assert event.permission == "tracker_write"
      assert event.source == :request
      assert event.reason == "comment on the PR thread"
      assert event.run_id == ctx.run.id
      assert event.actor =~ ctx.task.id
    end

    test "raises :permission_requested to the coordinator through Escalation.post/1", ctx do
      assert {:ok, _} =
               request(ctx.worker, %{"permission" => "tracker_write", "reason" => "comment"})

      issue = Ash.get!(Issue, ctx.task.id)
      assert issue.attention_cause == :permission_requested

      assert %{owner: :coordinator, cause: :permission_requested, waiting_on: :permission_grant} =
               Attention.current(issue)

      assert %{escalation_kind: :permission_requested, to_ref: to_ref, task_ref: task_ref} =
               Message.last_escalation(:permission_requested,
                 workspace_id: ctx.ws.id,
                 task_ref: ctx.task.id
               )

      assert to_ref == Message.coordinator_ref()
      assert task_ref == ctx.task.id
    end

    test "is the operator's when the binding says grant_by: operator", ctx do
      assert {:ok, data} =
               request(ctx.worker, %{"permission" => "prod_ssh", "reason" => "read the logs"})

      assert data.grant_by == "operator"

      issue = Ash.get!(Issue, ctx.task.id)
      assert %{owner: :operator, cause: :permission_requested} = Attention.current(issue)
    end

    test "a coordinator-grant request stays pending until the coordinator grants it", ctx do
      assert {:ok, %{grant_by: "coordinator"}} =
               request(ctx.worker, %{"permission" => "prod_read", "reason" => "inspect rows"})

      issue = Ash.get!(Issue, ctx.task.id)
      assert Permissions.pending(issue) == ["prod_read"]
      refute "prod_read" in issue.permissions

      assert {:ok, granted} = Permissions.grant(issue, "prod_read", authority: :coordinator)
      assert "prod_read" in granted.permissions
      assert Permissions.pending(granted) == []
    end

    test "a repeat of a pending request records nothing new", ctx do
      args = %{"permission" => "tracker_write", "reason" => "comment"}
      assert {:ok, first} = request(ctx.worker, args)
      refute first.already_requested

      assert {:ok, second} = request(ctx.worker, args)
      assert second.already_requested
      assert length(requested_events(ctx.task.id)) == 1
    end

    test "a permission already in force is a conflict", ctx do
      {:ok, _} = Ash.update(ctx.task, %{permissions: ["tracker_write"]}, action: :set_permissions)

      assert {:tool_error, message, "conflict"} =
               request(ctx.worker, %{"permission" => "tracker_write", "reason" => "again"})

      assert message =~ "already"
      assert requested_events(ctx.task.id) == []
    end
  end

  describe "it grants nothing" do
    test "says recorded, not granted, and leaves the ticket's reach alone", ctx do
      before_issue = Ash.get!(Issue, ctx.task.id)

      assert {:ok, data} =
               request(ctx.worker, %{
                 "permission" => "network:api.example.com:443",
                 "reason" => "x"
               })

      assert data.recorded == true
      assert data.granted == false
      assert data.status == "recorded, not granted"

      after_issue = Ash.get!(Issue, ctx.task.id)
      assert after_issue.permissions == before_issue.permissions
      refute "network:api.example.com:443" in Permissions.in_force(after_issue)

      assert "network:api.example.com:443" in Permissions.pending(after_issue)

      refute Enum.any?(Permissions.events(after_issue), &(&1.event in [:granted, :declared]))
    end
  end

  describe "a request is not a trust violation" do
    test "records no guardrail event", ctx do
      assert {:ok, _} =
               request(ctx.worker, %{"permission" => "prod_ssh", "reason" => "read the logs"})

      assert Events.for_run(ctx.run.id) == []
      assert Events.for_run(ctx.task.id) == []
    end

    test "an egress denial for the requested host is not an unrequested-egress event", ctx do
      assert {:ok, _} =
               request(ctx.worker, %{"permission" => "network:api.example.com", "reason" => "x"})

      Ash.create!(Arbiter.Worker.Egress.Event, %{
        run_id: ctx.run.id,
        task_id: ctx.task.id,
        host: "api.example.com",
        port: 443,
        decision: :deny,
        reason: :not_granted,
        mode: :enforce,
        policy_verdict: :deny
      })

      :ok = Events.link_egress(ctx.run.id)
      assert Events.for_run(ctx.run.id) == []
    end
  end
end
