defmodule Arbiter.Tasks.PermissionDecisionTest do
  @moduledoc """
  bd-lozakf (G15b, `docs/design/guardrail-profiles.md` §5.6): the answer side of
  a mid-run permission request. A grant is checked against the binding's
  `grant_by`, lands on the ticket, and a `network:` grant reaches the running
  worker's proxy at once; a denial reaches the worker's inbox with its reason.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Projection
  alias Arbiter.Messages.Mailbox
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PermissionDecision
  alias Arbiter.Tasks.PermissionRequest
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Withholding

  @guardrails %{
    "bindings" => %{
      "prod_read" => %{
        "grant_by" => "coordinator",
        "enforced_read_only" => true,
        "env_from_secret" => %{"RO_URL" => "prod_ro_url"}
      },
      "prod_ssh" => %{"grant_by" => "operator", "hosts" => ["prod.internal:22"]}
    }
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "permdec-#{System.unique_integer([:positive])}",
        prefix: "pd",
        config: %{"guardrails" => @guardrails},
        secrets: %{"prod_ro_url" => "postgres://ro"}
      })

    {:ok, task} = Ash.create(Issue, %{title: "needs reach", workspace_id: ws.id})
    task = put_state!(task, :active)
    %{ws: ws, task: task}
  end

  defp ask(task, permission, reason \\ "need it") do
    {:ok, _} = PermissionRequest.submit(task, permission, reason, actor: "worker")
    Ash.get!(Issue, task.id)
  end

  defp coordinator, do: [authority: :coordinator, actor: "coordinator"]
  defp operator, do: [authority: :operator, actor: "operator"]

  defp inbox(task) do
    Mailbox.list(to_ref: task.id, state: :any)
  end

  describe "grant/3" do
    test "puts the permission on the ticket and records granted with the actor", %{task: task} do
      task = ask(task, "prod_read")
      assert Permissions.pending(task) == ["prod_read"]

      assert {:ok, %{permission: "prod_read", decision: :granted, issue: issue}} =
               PermissionDecision.grant(task, "prod_read", coordinator())

      assert "prod_read" in issue.permissions
      assert Permissions.pending(issue) == []
      assert "prod_read" in Permissions.in_force(issue)

      assert %{event: :granted, actor: "coordinator", source: :system} =
               task.id |> Permissions.events() |> List.last()
    end

    test "an operator-only binding is refused to a coordinator and decided by the operator",
         %{task: task} do
      task = ask(task, "prod_ssh")

      assert {:error, {:forbidden, message}} =
               PermissionDecision.grant(task, "prod_ssh", coordinator())

      assert message =~ "operator"
      assert Permissions.pending(task) == ["prod_ssh"]
      refute "prod_ssh" in Ash.get!(Issue, task.id).permissions

      assert {:ok, %{decision: :granted}} = PermissionDecision.grant(task, "prod_ssh", operator())

      assert %{event: :granted, actor: "operator"} =
               task.id |> Permissions.events() |> List.last()
    end

    test "a restricted authority may not grant", %{task: task} do
      task = ask(task, "prod_read")

      assert {:error, {:forbidden, _}} =
               PermissionDecision.grant(task, "prod_read", authority: :restricted)
    end

    test "something nobody asked for has nothing to decide", %{task: task} do
      assert {:error, {:conflict, message}} =
               PermissionDecision.grant(task, "prod_read", coordinator())

      assert message =~ "nothing to decide"
    end

    test "a malformed permission is invalid", %{task: task} do
      assert {:error, {:invalid, _}} = PermissionDecision.grant(task, "nope", coordinator())
    end

    test "clears the permission_requested attention once nothing is pending", %{task: task} do
      task = ask(task, "prod_read")
      assert Ash.get!(Issue, task.id).attention_cause == :permission_requested

      {:ok, _} = PermissionDecision.grant(task, "prod_read", coordinator())

      assert Ash.get!(Issue, task.id).attention_cause == nil
    end

    test "keeps the attention while another request is pending", %{task: task} do
      task = ask(task, "prod_read")
      task = ask(task, "network:api.example.com")

      {:ok, _} = PermissionDecision.grant(task, "prod_read", coordinator())

      issue = Ash.get!(Issue, task.id)
      assert issue.attention_cause == :permission_requested
      assert Permissions.pending(issue) == ["network:api.example.com:443"]
    end

    test "tells the worker its inbox what was granted", %{task: task} do
      task = ask(task, "prod_read")
      {:ok, _} = PermissionDecision.grant(task, "prod_read", coordinator())

      assert [%{from_ref: "coordinator", task_ref: ref, body: body}] = inbox(task)
      assert ref == task.id
      assert body =~ "prod_read"
      assert body =~ "granted"
    end
  end

  describe "deny/3" do
    test "records denied with the reason and the actor, and delivers it to the worker's inbox",
         %{task: task} do
      task = ask(task, "prod_read")

      assert {:ok, %{decision: :denied, issue: issue}} =
               PermissionDecision.deny(
                 task,
                 "prod_read",
                 coordinator() ++ [reason: "use the fixture dump instead"]
               )

      refute "prod_read" in issue.permissions
      assert Permissions.pending(issue) == []

      assert %{event: :denied, actor: "coordinator", reason: "use the fixture dump instead"} =
               task.id |> Permissions.events() |> List.last()

      assert [%{to_ref: to_ref, body: body, kind: kind}] = inbox(task)
      assert to_ref == task.id
      assert kind in Arbiter.Messages.Message.mailbox_kinds()
      assert body =~ "denied"
      assert body =~ "use the fixture dump instead"
    end

    test "needs a reason", %{task: task} do
      task = ask(task, "prod_read")

      assert {:error, {:invalid, message}} =
               PermissionDecision.deny(task, "prod_read", coordinator())

      assert message =~ "reason"
      assert Permissions.pending(task) == ["prod_read"]
      assert inbox(task) == []
    end

    test "an operator-only binding is not the coordinator's to deny", %{task: task} do
      task = ask(task, "prod_ssh")

      assert {:error, {:forbidden, _}} =
               PermissionDecision.deny(task, "prod_ssh", coordinator() ++ [reason: "no"])

      assert inbox(task) == []
    end

    test "the operator may deny it", %{task: task} do
      task = ask(task, "prod_ssh")

      assert {:ok, %{decision: :denied}} =
               PermissionDecision.deny(task, "prod_ssh", operator() ++ [reason: "not on prod"])

      assert %{event: :denied, actor: "operator"} = task.id |> Permissions.events() |> List.last()
    end

    test "a denial clears the attention too", %{task: task} do
      task = ask(task, "prod_read")
      {:ok, _} = PermissionDecision.deny(task, "prod_read", coordinator() ++ [reason: "no"])
      assert Ash.get!(Issue, task.id).attention_cause == nil
    end
  end

  describe "a network: grant reaches the running worker" do
    setup do
      dir =
        Path.join(
          Arbiter.Config.Paths.socket_root(),
          "pdt#{Base.encode16(:crypto.strong_rand_bytes(4))}"
        )

      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

      {:ok, port} = :inet.port(listen)
      on_exit(fn -> :gen_tcp.close(listen) end)

      run_id = "pdrun#{System.unique_integer([:positive])}"
      on_exit(fn -> Egress.stop_run(run_id) end)
      %{dir: dir, port: port, run_id: run_id}
    end

    defp connect_status(path, authority) do
      {:ok, sock} =
        :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false], 2_000)

      :ok = :gen_tcp.send(sock, "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n")
      {:ok, data} = :gen_tcp.recv(sock, 0, 2_000)
      :gen_tcp.close(sock)
      "HTTP/1.1 " <> <<code::binary-size(3), _::binary>> = data
      String.to_integer(code)
    end

    defp start_proxy!(run_id, dir, task_id, grants) do
      {:ok, path} =
        Egress.start_run(run_id,
          dir: dir,
          allow_local_dial: true,
          task_id: task_id,
          grants: grants
        )

      path
    end

    test "an unguarded run's next CONNECT succeeds without a restart", ctx do
      %{task: task, dir: dir, port: port, run_id: run_id} = ctx
      authority = "127.0.0.1:#{port}"
      on_exit(fn -> Egress.invalidate_grants(task.id) end)

      path =
        start_proxy!(run_id, dir, task.id, Withholding.grants(task.id, Projection.unguarded()))

      task = ask(task, "network:" <> authority)
      assert connect_status(path, authority) == 403

      # Still pending: the proxy has not been told anything yet.
      assert connect_status(path, authority) == 403

      {:ok, _} = PermissionDecision.grant(task, "network:" <> authority, coordinator())
      assert connect_status(path, authority) == 200
    end

    test "a guarded run's next CONNECT succeeds too, under its dispatch-time profile", ctx do
      %{task: task, ws: ws, dir: dir, port: port, run_id: run_id} = ctx
      authority = "127.0.0.1:#{port}"
      on_exit(fn -> Egress.invalidate_grants(task.id) end)

      profile = %Profile{tier: :probation, permissions: ["network:"]}
      projection = Withholding.projection(task, ws, profile, :implementer)
      assert projection.guarded?
      assert projection.hosts == []

      path = start_proxy!(run_id, dir, task.id, Withholding.grants(task.id, projection))

      task = ask(task, "network:" <> authority)
      assert connect_status(path, authority) == 403

      {:ok, _} = PermissionDecision.grant(task, "network:" <> authority, coordinator())
      assert connect_status(path, authority) == 200
    end

    test "a guarded reviewer's proxy never gains an action grant", ctx do
      %{task: task, ws: ws, dir: dir, port: port, run_id: run_id} = ctx
      authority = "127.0.0.1:#{port}"
      on_exit(fn -> Egress.invalidate_grants(task.id) end)

      profile = %Profile{tier: :probation, permissions: ["network:"]}
      projection = Withholding.projection(task, ws, profile, :reviewer)
      path = start_proxy!(run_id, dir, task.id, Withholding.grants(task.id, projection))

      task = ask(task, "network:" <> authority)
      {:ok, _} = PermissionDecision.grant(task, "network:" <> authority, coordinator())
      assert connect_status(path, authority) == 403
    end

    test "revoking by denial of a later request does not widen anything", ctx do
      %{task: task, dir: dir, port: port, run_id: run_id} = ctx
      authority = "127.0.0.1:#{port}"
      on_exit(fn -> Egress.invalidate_grants(task.id) end)

      path =
        start_proxy!(run_id, dir, task.id, Withholding.grants(task.id, Projection.unguarded()))

      task = ask(task, "network:" <> authority)

      {:ok, _} =
        PermissionDecision.deny(
          task,
          "network:" <> authority,
          coordinator() ++ [reason: "not that host"]
        )

      assert connect_status(path, authority) == 403
    end
  end

  describe "env and mount grants take effect at the next spawn" do
    # A resume is a dispatch (`Dispatch.resume/2` delegates to `dispatch/2`), and a
    # dispatch projects the ticket's in-force permissions afresh through
    # `Withholding.for_spawn/5`: that is the whole re-projection.
    setup do
      put_app_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :privileged}
      ])

      :ok
    end

    test "a resume after the grant projects the binding's env; before it, nothing",
         %{task: task, ws: ws} do
      task = ask(task, "prod_read")

      pending = Withholding.for_spawn(task.id, ws, :claude, "sonnet")
      assert pending.guarded?
      assert pending.env == []
      assert pending.granted == []

      {:ok, _} = PermissionDecision.grant(task, "prod_read", coordinator())

      resumed = Withholding.for_spawn(task.id, ws, :claude, "sonnet")
      assert resumed.env == [{"RO_URL", "prod_ro_url"}]
      assert resumed.granted == ["prod_read"]
    end

    test "a denied permission is still projected as nothing", %{task: task, ws: ws} do
      task = ask(task, "prod_read")

      {:ok, _} =
        PermissionDecision.deny(task, "prod_read", coordinator() ++ [reason: "not needed"])

      denied = Withholding.for_spawn(task.id, ws, :claude, "sonnet")
      assert denied.env == []
      assert denied.granted == []
    end
  end
end
