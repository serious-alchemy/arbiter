defmodule Arbiter.Worker.WithholdingTest do
  @moduledoc """
  G14 (bd-ld8qde): the DB-facing half of dispatch-time withholding — in-force
  permissions of a real ticket, projected under a profile, plus the egress
  grants and the per-worker ssh-agent that projection asks for.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Projection
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Egress.GrantCache
  alias Arbiter.Worker.Withholding
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  @guardrails %{
    "bindings" => %{
      "prod_ssh" => %{"hosts" => ["prod.internal:22"], "ssh_key_secret" => "prod_ssh_key"},
      "prod_read" => %{
        "enforced_read_only" => true,
        "env_from_secret" => %{"RO_URL" => "prod_ro_url"}
      }
    }
  }

  defp privileged,
    do: %Profile{
      tier: :privileged,
      permissions: ["network:", "tracker_write", "secrets:", "prod_read", "prod_ssh"]
    }

  defp setup_ticket(perms, context) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wh-#{System.unique_integer([:positive])}",
        prefix: "wh",
        config: %{"guardrails" => @guardrails},
        secrets: %{"prod_ro_url" => "postgres://ro"}
      })

    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, permissions: perms}, context: context)

    {ws, issue}
  end

  defp coordinator, do: %{guardrail_authority: :coordinator, permission_actor: "c"}
  defp operator, do: %{guardrail_authority: :operator, permission_actor: "o"}

  describe "projection/4" do
    test "projects the ticket's in-force permissions under the profile" do
      {ws, issue} = setup_ticket(["network:api.example.com", "prod_read"], coordinator())
      p = Withholding.projection(issue, ws, privileged(), :implementer)

      assert p.guarded?
      assert p.hosts == ["api.example.com:443"]
      assert p.env == [{"RO_URL", "prod_ro_url"}]
    end

    test "a pending (operator-grant) permission is not projected until granted" do
      {ws, issue} = setup_ticket(["prod_ssh"], coordinator())
      p = Withholding.projection(issue, ws, privileged(), :implementer)
      assert p.ssh == nil and p.hosts == []
    end

    test "an operator-declared prod_ssh is projected" do
      {ws, issue} = setup_ticket(["prod_ssh"], operator())
      p = Withholding.projection(issue, ws, privileged(), :implementer)
      assert p.ssh == %{key_secret: "prod_ssh_key", hosts: ["prod.internal:22"]}
    end

    test "no profile: unguarded, legacy" do
      {ws, issue} = setup_ticket(["prod_read"], coordinator())
      refute Withholding.projection(issue, ws, nil, :implementer).guarded?
    end

    test "a synthetic review task id resolves to the base ticket but projects nothing" do
      {ws, issue} = setup_ticket(["network:api.example.com"], coordinator())
      p = Withholding.projection(issue, ws, privileged(), :reviewer)
      assert p.hosts == []
      assert [%{reason: reason}] = p.withheld
      assert reason =~ "reviewer"
    end
  end

  describe "for_spawn/5" do
    setup do
      Application.put_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :privileged},
        %{match: %{provider: "antigravity"}, tier: :probation}
      ])

      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)
    end

    test "resolves the subject's tier: a privileged subject gets prod_read, a probation one does not" do
      {ws, issue} = setup_ticket(["prod_read", "network:api.example.com"], coordinator())

      claude = Withholding.for_spawn(issue.id, ws, :claude, "claude-opus-4", role: :implementer)
      assert claude.env == [{"RO_URL", "prod_ro_url"}]

      agy = Withholding.for_spawn(issue.id, ws, :gemini, "gemini-3", role: :implementer)
      # no rule matches "gemini" -> quarantine: nothing at all
      assert agy.env == [] and agy.hosts == []
    end

    test "a synthetic id resolves the base ticket; a reviewer gets nothing" do
      {ws, issue} = setup_ticket(["network:api.example.com"], coordinator())
      p = Withholding.for_spawn(issue.id <> "#review", ws, :claude, nil, role: :reviewer)
      assert p.guarded? and p.hosts == []
    end

    test "a ticket that cannot be loaded fails closed when guarded" do
      {ws, _} = setup_ticket([], coordinator())
      p = Withholding.for_spawn("no-such-ticket", ws, :claude, nil, role: :implementer)
      assert p.guarded? and p.hosts == [] and p.env == []
    end

    test "with no rules configured it is unguarded" do
      Application.delete_env(:arbiter, :guardrail_subject_rules)
      {ws, issue} = setup_ticket(["prod_read"], coordinator())
      refute Withholding.for_spawn(issue.id, ws, :claude, nil, role: :implementer).guarded?
    end
  end

  describe "check_spawn/2" do
    test "no ssh projection: any provider" do
      for provider <- ["claude", "codex", "gemini", nil] do
        assert :ok = Withholding.check_spawn(Projection.sealed(), provider)
      end

      assert :ok = Withholding.check_spawn(nil, "claude")
    end

    test "prod_ssh needs the jail's agent: only agy has one" do
      projection = %{Projection.sealed() | ssh: %{key_secret: "k", hosts: []}}
      assert :ok = Withholding.check_spawn(projection, "gemini")

      for provider <- ["claude", "codex", nil] do
        assert {:error, {:prod_ssh_unsupported, _}} =
                 Withholding.check_spawn(projection, provider)
      end
    end
  end

  describe "grants/2" do
    test "a guarded spawn gets exactly what was projected, not a live DB read" do
      {_ws, issue} = setup_ticket(["network:later.example.com"], coordinator())
      projection = %{Projection.sealed() | hosts: ["api.example.com:443"]}
      assert Withholding.grants(issue.id, projection).(issue.id) == ["api.example.com:443"]
    end

    test "an unguarded spawn reads the ticket's in-force network: grants live" do
      {_ws, issue} =
        setup_ticket(["network:api.example.com", "network?:opt.example.com"], coordinator())

      loader = Withholding.grants(issue.id, Projection.unguarded())
      assert Enum.sort(loader.(issue.id)) == ["api.example.com:443", "opt.example.com:443"]
    end

    test "a synthetic task id reads the base ticket" do
      {_ws, issue} = setup_ticket(["network:api.example.com"], coordinator())
      loader = Withholding.grants(issue.id <> "#r1", Projection.unguarded())
      assert loader.(issue.id <> "#r1") == ["api.example.com:443"]
    end

    test "two spawns of one task never read each other's grants through the cache" do
      {_ws, issue} = setup_ticket(["network:api.example.com"], coordinator())

      implementer =
        Withholding.grants(issue.id, %{Projection.sealed() | hosts: ["api.example.com:443"]})

      reviewer = Withholding.grants(issue.id, Projection.sealed(role: :reviewer))

      assert GrantCache.fetch(issue.id, "run-impl", implementer) == ["api.example.com:443"]
      assert GrantCache.fetch(issue.id, "run-review", reviewer) == []
      # and back: the reviewer's empty answer is not what the implementer now reads
      assert GrantCache.fetch(issue.id, "run-impl", reviewer) == ["api.example.com:443"]

      # a grant writer's invalidation still reaches every run of the task
      GrantCache.invalidate(issue.id)
      assert GrantCache.fetch(issue.id, "run-impl", reviewer) == []
    end
  end

  describe "CI fix-pass spawn (FixPassDispatcher.spawn_projection/2)" do
    test "a guarded install projects the pass like any implementer spawn, not a seal" do
      Application.put_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :privileged}
      ])

      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)

      {ws, issue} = setup_ticket(["prod_read", "tracker_write"], coordinator())
      context = %{task: issue, workspace: ws, repo: nil}

      projection = FixPassDispatcher.spawn_projection(context, :claude)

      assert projection.guarded?
      assert projection.env == [{"RO_URL", "prod_ro_url"}]
      assert "tracker_write" in projection.claims
    end

    test "with no subject rule configured the pass is unguarded, as before G14" do
      {ws, issue} = setup_ticket([], coordinator())
      context = %{task: issue, workspace: ws, repo: nil}
      refute FixPassDispatcher.spawn_projection(context, :claude).guarded?
    end
  end

  describe "ssh_agent/3" do
    test "nothing to start without a prod_ssh projection" do
      {ws, _} = setup_ticket([], coordinator())
      assert {:ok, nil} = Withholding.ssh_agent(Projection.sealed(), ws, self())
    end

    test "a missing key secret is an error, not a silent no-agent spawn" do
      {ws, _} = setup_ticket([], coordinator())
      projection = %{Projection.sealed() | ssh: %{key_secret: "nope", hosts: []}}
      assert {:error, {:ssh_key_missing, "nope"}} = Withholding.ssh_agent(projection, ws, self())
    end

    @tag :tmp_dir
    test "starts an agent holding the workspace secret's key", %{tmp_dir: tmp} do
      key_path = Path.join(tmp, "k")
      {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key_path])

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wh-#{System.unique_integer([:positive])}",
          secrets: %{"prod_ssh_key" => File.read!(key_path)}
        })

      dir = Path.join(System.tmp_dir!(), "wsa#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      projection = %{Projection.sealed() | ssh: %{key_secret: "prod_ssh_key", hosts: []}}

      assert {:ok, socket} = Withholding.ssh_agent(projection, ws, self(), dir: dir)
      assert {out, 0} = System.cmd("ssh-add", ["-l"], env: [{"SSH_AUTH_SOCK", socket}])
      assert out =~ "ED25519"
    end
  end
end
