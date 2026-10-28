defmodule Arbiter.StandingOrdersInjectionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.StandingOrders
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Tasks.Workspace.Operations
  alias Arbiter.Worker.{PromptBuilder, ReviewGate, RunProvenance}
  alias Arbiter.Workflows.MergeQueue.{ConflictResolver, FixPassDispatcher}

  @order "Never touch the vendored parser directory"
  @heading "## Workspace standing orders"

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "so-inject", prefix: "soi"})

    {:ok, task} =
      Ash.create(Issue, %{
        title: "t",
        description: "body",
        acceptance: "- [ ] x",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, ws: ws, task: task}
  end

  defp with_order(ws, order \\ @order) do
    {:ok, ws} = Operations.add_standing_order(ws, order)
    ws
  end

  defp rg_state(task) do
    %{
      task_id: task.id,
      workspace_id: task.workspace_id,
      branch: "feature/rev",
      target_branch: "main",
      worktree_path: nil,
      round: 1,
      head_sha: nil,
      base_sha: "abc1234",
      thread: [],
      findings: []
    }
  end

  describe "implement / resume prompt" do
    test "carries the labelled section", %{ws: ws, task: task} do
      ws = with_order(ws)
      prompt = PromptBuilder.prompt_for_task(task, workspace: ws)
      assert prompt =~ @heading
      assert prompt =~ @order
    end

    test "resume context path carries it too", %{ws: ws, task: task} do
      ws = with_order(ws)
      prompt = PromptBuilder.prompt_for_task(task, workspace: ws, resume_context: "RESUME\n")
      assert prompt =~ @order
    end

    test "a no-PR task carries it", %{ws: ws, task: task} do
      ws = with_order(ws)
      prompt = PromptBuilder.prompt_for_task(%{task | issue_type: :research}, workspace: ws)
      assert prompt =~ @order
    end

    test "none without orders", %{ws: ws, task: task} do
      refute PromptBuilder.prompt_for_task(task, workspace: ws) =~ "standing orders"
      refute PromptBuilder.prompt_for_task(task, []) =~ "standing orders"
    end
  end

  describe "fix_pass prompt" do
    test "carries it; absent without orders", %{ws: ws, task: task} do
      ctx = %{task: task, branch: "b", target_branch: "main", checks: []}
      refute FixPassDispatcher.prompt_for(Map.put(ctx, :workspace, ws)) =~ "standing orders"
      prompt = FixPassDispatcher.prompt_for(Map.put(ctx, :workspace, with_order(ws)))
      assert prompt =~ @heading
      assert prompt =~ @order
    end
  end

  describe "conflict prompt" do
    test "briefing and resolver carry it; absent without orders", %{ws: ws, task: task} do
      refute PromptBuilder.conflict_resolve_briefing(task, "b", "main", workspace: ws) =~
               "standing orders"

      ws = with_order(ws)
      assert PromptBuilder.conflict_resolve_briefing(task, "b", "main", workspace: ws) =~ @order

      prompt =
        ConflictResolver.prompt_for(%{
          task: task,
          branch: "b",
          target_branch: "main",
          workspace: ws
        })

      assert prompt =~ @heading
      assert prompt =~ @order
    end
  end

  describe "review prompts" do
    test "ReviewGate review_prompt carries it; absent without orders", %{ws: ws, task: task} do
      refute ReviewGate.review_prompt(rg_state(task)) =~ "standing orders"
      with_order(ws)
      prompt = ReviewGate.review_prompt(rg_state(task))
      assert prompt =~ @heading
      assert prompt =~ @order
    end

    test "dispatch review: true prompt carries it", %{ws: ws, task: task} do
      ws = with_order(ws)
      assert PromptBuilder.prompt_for_task(task, review: true, workspace: ws) =~ @order
    end

    test "revise prompt carries it", %{ws: ws, task: task} do
      with_order(ws)
      assert ReviewGate.revise_prompt(rg_state(task), "finding") =~ @order
    end

    test "a removed order no longer appears", %{ws: ws, task: task} do
      ws = with_order(ws)
      assert ReviewGate.review_prompt(rg_state(task)) =~ @order
      {:ok, _} = Operations.remove_standing_order(ws, 1)
      refute ReviewGate.review_prompt(rg_state(task)) =~ @order
      refute ReviewGate.review_prompt(rg_state(task)) =~ "standing orders"
    end
  end

  describe "digest" do
    test "is computed from exactly the injected text", %{ws: ws} do
      assert RunProvenance.standing_orders_digest(ws) == nil
      assert StandingOrders.section(ws) == ""

      ws1 = with_order(ws)
      ws2 = with_order(ws1, "Second order")
      d1 = RunProvenance.standing_orders_digest(ws1)
      d2 = RunProvenance.standing_orders_digest(ws2)

      assert d1 != d2
      assert StandingOrders.section(ws1) != StandingOrders.section(ws2)

      assert d1 ==
               :sha256
               |> :crypto.hash(StandingOrders.text(ws1))
               |> Base.encode16(case: :lower)

      assert StandingOrders.section(ws2) =~ StandingOrders.text(ws2)
    end
  end
end
