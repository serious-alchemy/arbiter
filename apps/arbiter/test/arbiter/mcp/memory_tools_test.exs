defmodule Arbiter.MCP.MemoryToolsTest do
  @moduledoc """
  The memory promotion and quarantine MCP tools (bd-19qve3), called through
  `Arbiter.MCP.Catalog.call/3` so the tier gate and the handler gate are both
  exercised.

  Amendment 5: writing into the shared layer every future session reads is
  coordinator/operator authority. apply, reject and restore are refused for
  worker, refine **and session** tokens. A browser-hosted session's token is
  minted at the coordinator tier (`Arbiter.MCP.Scope.mint_session/2`), so the
  tier alone is not enough. The refusal must not touch the queue.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.MemoryFixture

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.SessionArchive

  @moduletag :tmp_dir

  @short "defmodule Short do\n  def hello, do: :world\nend\n"
  @not_permitted -32_003

  @coordinator %Scope{tier: :coordinator}
  @session %Scope{tier: :coordinator, session_id: "0199aaaa-0000-7000-8000-000000000001"}
  @worker %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
  @refine %Scope{tier: :refine, workspace_id: "w", issue_id: "bd-1", session_id: "s"}

  @writes ~w(memory_pending_apply memory_pending_reject memory_quarantine_restore)
  @reads ~w(memory_pending_list memory_pending_diff memory_quarantine_list)

  setup %{tmp_dir: tmp_dir} do
    sessions_root = Path.join(tmp_dir, "sessions")
    memory_root = Path.join(tmp_dir, "memory")
    File.mkdir_p!(memory_root)

    prior =
      for key <- [:sessions_root, :memory_root],
          into: %{},
          do: {key, Application.get_env(:arbiter, key)}

    Application.put_env(:arbiter, :sessions_root, sessions_root)
    Application.put_env(:arbiter, :memory_root, memory_root)

    on_exit(fn ->
      for {key, value} <- prior do
        if value,
          do: Application.put_env(:arbiter, key, value),
          else: Application.delete_env(:arbiter, key)
      end
    end)

    # The real resolution path: a workspace whose repo_paths names the checkout.
    checkout = checkout!(%{"lib/short.ex" => @short})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "memory-mcp",
        prefix: "memm",
        config: %{"repo_paths" => %{"short" => checkout}}
      })

    {:ok, memory_root: memory_root, ws: ws, checkout: checkout}
  end

  defp candidate!(session_id, filename, type, body, opts \\ []) do
    write_memory!(Layout.memory_candidates_dir(session_id), filename, type, body, opts)
  end

  defp quarantine!(ctx) do
    write_memory!(ctx.memory_root, "stale.md", "project", "See lib/short.ex:99.",
      workspace_id: ctx.ws.id
    )

    %{quarantined: [{"stale.md", name}]} = Checker.run(memory_root: ctx.memory_root)
    name
  end

  describe "who may write the shared layer" do
    test "a session token is refused apply, reject and restore, and nothing changes", ctx do
      path = candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")
      quarantined = quarantine!(ctx)

      calls = [
        {"memory_pending_apply", %{"id" => "sess-1/habit.md"}},
        {"memory_pending_reject", %{"id" => "sess-1/habit.md", "reason" => "no"}},
        {"memory_quarantine_restore", %{"name" => quarantined}}
      ]

      for {tool, args} <- calls do
        assert {:rpc_error, @not_permitted, message} = Catalog.call(@session, tool, args)
        assert message =~ "session"
      end

      assert File.exists?(path)
      refute File.exists?(Path.join(ctx.memory_root, "habit.md"))
      assert File.exists?(Path.join([ctx.memory_root, "quarantined", quarantined]))
    end

    test "worker and refine tokens cannot reach any memory tool" do
      for scope <- [@worker, @refine], tool <- @writes ++ @reads ++ ["memory_distill"] do
        assert {:rpc_error, @not_permitted, _} = Catalog.call(scope, tool, %{}),
               "#{scope.tier} reached #{tool}"
      end
    end

    test "a session token may still read the queue and the quarantine" do
      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")

      assert {:ok, %{count: 1}} = Catalog.call(@session, "memory_pending_list", %{})

      assert {:ok, %{content: _}} =
               Catalog.call(@session, "memory_pending_diff", %{"id" => "sess-1/habit.md"})

      assert {:ok, %{count: 0}} = Catalog.call(@session, "memory_quarantine_list", %{})
    end
  end

  describe "the coordinator" do
    test "promotes with provenance, verified against the workspace's checkout", ctx do
      candidate!("sess-1", "proj.md", "project", "Greeting at lib/short.ex:2.",
        workspace_id: ctx.ws.id
      )

      assert {:ok, %{memory: "proj.md", status: "ok"}} =
               Catalog.call(@coordinator, "memory_pending_apply", %{"id" => "sess-1/proj.md"})

      fields = ctx.memory_root |> Path.join("proj.md") |> File.read!() |> Frontmatter.fields()
      assert fields["promoted_by"] == "coordinator"
      assert fields["source_session"] == "sess-1"
      assert fields["verified_sha"] == head!(ctx.checkout)
    end

    test "a stale candidate is refused with the reasons", ctx do
      candidate!("sess-1", "proj.md", "project", "See lib/short.ex:100.", workspace_id: ctx.ws.id)

      assert {:tool_error, message, _type} =
               Catalog.call(@coordinator, "memory_pending_apply", %{"id" => "sess-1/proj.md"})

      assert message =~ "lib/short.ex:100"
    end

    test "replacing a shared memory needs overwrite, which the schema accepts", ctx do
      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")
      File.write!(Path.join(ctx.memory_root, "habit.md"), "old\n")

      assert {:tool_error, message, _type} =
               Catalog.call(@coordinator, "memory_pending_apply", %{"id" => "sess-1/habit.md"})

      assert message =~ "overwrite"

      assert {:ok, %{memory: "habit.md"}} =
               Catalog.call(@coordinator, "memory_pending_apply", %{
                 "id" => "sess-1/habit.md",
                 "overwrite" => true
               })
    end

    test "rejects with a reason, and a missing reason is a usable error", _ctx do
      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")

      assert {:tool_error, message, _type} =
               Catalog.call(@coordinator, "memory_pending_reject", %{"id" => "sess-1/habit.md"})

      assert message =~ "reason"

      assert {:ok, %{rejected: true}} =
               Catalog.call(@coordinator, "memory_pending_reject", %{
                 "id" => "sess-1/habit.md",
                 "reason" => "vague"
               })

      assert {:ok, %{count: 1, candidates: [%{rejection_reason: "vague"}]}} =
               Catalog.call(@coordinator, "memory_pending_list", %{"state" => "rejected"})
    end

    test "lists quarantine with reasons, and restore refuses until the memory is fixed", ctx do
      name = quarantine!(ctx)

      assert {:ok, %{count: 1, quarantined: [%{name: ^name, reason: reason}]}} =
               Catalog.call(@coordinator, "memory_quarantine_list", %{})

      assert reason =~ "lib/short.ex:99"

      assert {:tool_error, message, _type} =
               Catalog.call(@coordinator, "memory_quarantine_restore", %{"name" => name})

      assert message =~ "lib/short.ex:99"

      path = Path.join([ctx.memory_root, "quarantined", name])
      File.write!(path, String.replace(File.read!(path), "lib/short.ex:99", "lib/short.ex:2"))

      assert {:ok, %{memory: "stale.md", status: "ok"}} =
               Catalog.call(@coordinator, "memory_quarantine_restore", %{"name" => name})
    end
  end

  describe "memory_distill (bd-avt4lt)" do
    @distill_sid "0199cccc-0000-7000-8000-000000000014"
    @proposal %{
      "name" => "rebase-not-merge",
      "description" => "The operator rebases feature branches",
      "type" => "feedback",
      "turn_range" => [1, 1],
      "body" => "Rebase onto main; never merge main in."
    }

    setup %{tmp_dir: tmp_dir} do
      keys = [:output_log_root, :transcript_distillation_invoker, :transcript_distillation]
      prior = Map.new(keys, &{&1, Application.fetch_env(:arbiter, &1)})
      Application.put_env(:arbiter, :output_log_root, Path.join(tmp_dir, "logs"))

      on_exit(fn ->
        for {key, value} <- prior do
          case value do
            {:ok, value} -> Application.put_env(:arbiter, key, value)
            :error -> Application.delete_env(:arbiter, key)
          end
        end
      end)

      path = SessionArchive.path_for(@distill_sid)
      File.mkdir_p!(Path.dirname(path))
      turn = %{"type" => "user", "message" => %{"content" => "Always rebase, never merge."}}
      File.write!(path, :zlib.gzip(Jason.encode!(turn) <> "\n"))
      :ok
    end

    defp distill_invoker!(proposals) do
      test = self()

      Application.put_env(:arbiter, :transcript_distillation_invoker, fn _prompt, opts ->
        send(test, {:invoked, opts})
        reply = Jason.encode!(%{"candidates" => proposals})
        {:ok, reply, %{model: "claude-test", cost_usd: 0.01}}
      end)
    end

    test "queues candidates that memory_pending_list then shows" do
      distill_invoker!([@proposal])

      assert {:ok, %{candidates: [%{id: id, turn_range: "1-1"}], rejected: [], cost: cost}} =
               Catalog.call(@coordinator, "memory_distill", %{"session_id" => @distill_sid})

      assert is_binary(cost.usage_event_id)

      assert {:ok, %{candidates: [%{id: ^id, type: "feedback"}]}} =
               Catalog.call(@coordinator, "memory_pending_list", %{})
    end

    test "is refused for a session token, which spends and queues nothing" do
      distill_invoker!([@proposal])

      assert {:rpc_error, @not_permitted, message} =
               Catalog.call(@session, "memory_distill", %{"session_id" => @distill_sid})

      assert message =~ "session"
      refute_received {:invoked, _}
      assert Promotion.list_candidates() == []
    end

    test "its bounds can lower the configured caps, never raise them" do
      distill_invoker!([@proposal, Map.put(@proposal, "name", "second")])

      Application.put_env(:arbiter, :transcript_distillation,
        max_cost_usd: 0.4,
        max_candidates: 5
      )

      assert {:ok, %{candidates: [_], rejected: [%{reason: "over_candidate_cap"}]}} =
               Catalog.call(@coordinator, "memory_distill", %{
                 "session_id" => @distill_sid,
                 "max_cost_usd" => 100,
                 "max_candidates" => 1
               })

      assert_received {:invoked, opts}
      assert opts[:max_budget_usd] == 0.4
    end

    test "passes on the CLI's own error when the model call failed" do
      Application.put_env(:arbiter, :transcript_distillation_invoker, fn _prompt, _opts ->
        {:ok, "Not logged in · Please run /login", %{cost_usd: 0.0, is_error: true}}
      end)

      assert {:tool_error, "the model call failed: Not logged in · Please run /login." <> _,
              _type} =
               Catalog.call(@coordinator, "memory_distill", %{"session_id" => @distill_sid})
    end

    test "says why a pass was refused" do
      distill_invoker!([@proposal])

      refusals = [
        {%{"session_id" => "0199dddd-0000-7000-8000-000000000000"}, "no archived transcript"},
        {%{}, "session_id"},
        {%{"session_id" => @distill_sid, "max_cost_usd" => "lots"}, "max_cost_usd"},
        {%{"session_id" => @distill_sid, "max_candidates" => 0}, "max_candidates"}
      ]

      for {args, expected} <- refusals do
        assert {:tool_error, message, _type} = Catalog.call(@coordinator, "memory_distill", args)
        assert message =~ expected
      end

      refute_received {:invoked, _}
    end
  end
end
