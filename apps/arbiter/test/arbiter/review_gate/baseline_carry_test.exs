defmodule Arbiter.ReviewGate.BaselineCarryTest do
  @moduledoc """
  bd-2oo8kf / #1062 — a ruling or an APPROVE baseline on head H survives a sync
  to H' only when H' is H plus the target's own delta; any other content voids
  it exactly as before. Real git repositories, real resolution / round rows.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture

  alias Arbiter.ReviewGate.{BaselineCarry, MergeAuthorization, Resolutions, Round, RoundsReport}
  alias Arbiter.Tasks.{Issue, Workspace}

  defp task! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "bc-#{System.unique_integer([:positive])}",
        prefix: "bc",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} = Ash.create(Issue, %{title: "carried", workspace_id: ws.id, issue_type: :feature})
    task
  end

  defp round!(task, verdict) do
    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: verdict,
        findings: if(verdict == :approve, do: "", else: "[high] a.ex:1 needs a guard"),
        finding_count: if(verdict == :approve, do: 0, else: 1)
      })
  end

  defp rule!(task, head) do
    {:ok, ruling} =
      Resolutions.record(
        %{
          task_id: task.id,
          decision: :accept_as_is,
          reasoning: "ship it",
          head_sha: head,
          actor: "coordinator"
        },
        resume: false
      )

    ruling
  end

  defp stamp!(task, sha), do: Ash.update!(Ash.get!(Issue, task.id), %{last_reviewed_sha: sha})

  defp reviewed_sha(task), do: Ash.get!(Issue, task.id).last_reviewed_sha

  # `feature` holds two reviewed commits; the clone has fetched it.
  defp fixture do
    fx = origin_and_clone(%{"lib/a.ex" => "a1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    commit!(fx.origin, %{"lib/a.ex" => "a1\na2\n"}, "feature one")
    reviewed = commit!(fx.origin, %{"lib/new.ex" => "n1\n"}, "feature two")
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, %{"lib/b.ex" => "b1\n"}, "main moves")
    Map.put(fx, :reviewed, reviewed)
  end

  defp rebase!(fx) do
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["rebase", "-q", "main"])
    sha = git!(fx.origin, ["rev-parse", "HEAD"])
    git!(fx.origin, ["checkout", "-q", "main"])
    sha
  end

  defp merge_main!(fx) do
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["merge", "-q", "--no-ff", "--no-edit", "main"])
    sha = git!(fx.origin, ["rev-parse", "HEAD"])
    git!(fx.origin, ["checkout", "-q", "main"])
    sha
  end

  defp request(fx, task, to),
    do: %{
      task_id: task.id,
      workspace_id: task.workspace_id,
      from: fx.reviewed,
      to: to,
      repo_path: fx.clone,
      base: "main"
    }

  describe "an accept_as_is ruling" do
    setup do
      fx = fixture()
      task = task!()
      round!(task, :request_changes)
      rule!(task, fx.reviewed)
      stamp!(task, fx.reviewed)
      {:ok, fx: fx, task: task}
    end

    test "survives a rebase with identical patch-ids and the merge proceeds", %{fx: fx, task: task} do
      rebased = rebase!(fx)
      assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, rebased)

      assert {:carried, :ruling, proof} = BaselineCarry.carry(request(fx, task, rebased))
      assert proof =~ "patch-id"

      assert :ok = MergeAuthorization.check(task.id, rebased)
      assert reviewed_sha(task) == rebased

      # who / what / why in the rounds list
      report = RoundsReport.build(task.id)
      carried = List.last(report.resolutions)
      assert carried.head_sha == rebased
      assert carried.actor == "system:ruling-resume"
      assert carried.reasoning =~ fx.reviewed
      assert carried.reasoning =~ "patch-id"
      assert carried.reasoning =~ "coordinator"
    end

    test "survives a merge of the target whose tree equals merge-tree", %{fx: fx, task: task} do
      merged = merge_main!(fx)

      assert {:carried, :ruling, proof} = BaselineCarry.carry(request(fx, task, merged))
      assert proof =~ "merge-tree"
      assert :ok = MergeAuthorization.check(task.id, merged)
      assert reviewed_sha(task) == merged
    end

    test "an extra commit after a rebase voids it, exactly as today", %{fx: fx, task: task} do
      _rebased = rebase!(fx)
      git!(fx.origin, ["checkout", "-q", "feature"])
      extra = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      assert :void = BaselineCarry.carry(request(fx, task, extra))
      assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, extra)
      assert reviewed_sha(task) == fx.reviewed
      assert length(Resolutions.list(task.id)) == 1
    end

    test "a merge that smuggles a hunk voids it", %{fx: fx, task: task} do
      git!(fx.origin, ["checkout", "-q", "feature"])
      git!(fx.origin, ["merge", "-q", "--no-ff", "--no-commit", "main"])
      File.write!(Path.join(fx.origin, "lib/evil.ex"), "smuggled\n")
      git!(fx.origin, ["add", "lib/evil.ex"])
      git!(fx.origin, ["commit", "-q", "-m", "merge main"])
      evil = git!(fx.origin, ["rev-parse", "HEAD"])

      assert :void = BaselineCarry.carry(request(fx, task, evil))
      assert {:error, {:review_not_approved, _}} = MergeAuthorization.check(task.id, evil)
      assert length(Resolutions.list(task.id)) == 1
    end

    test "a ruling is not carried from a head it was not recorded against", %{fx: fx, task: task} do
      rebased = rebase!(fx)
      other = String.duplicate("a", 40)

      assert :void = BaselineCarry.carry(%{request(fx, task, rebased) | from: other})
    end
  end

  describe "an APPROVE baseline" do
    setup do
      fx = fixture()
      task = task!()
      round!(task, :approve)
      stamp!(task, fx.reviewed)
      {:ok, fx: fx, task: task}
    end

    test "survives a rebase with identical patch-ids: the latch is re-stamped", %{fx: fx, task: task} do
      rebased = rebase!(fx)

      assert {:carried, :approval, proof} = BaselineCarry.carry(request(fx, task, rebased))
      assert proof =~ "patch-id"
      assert reviewed_sha(task) == rebased
    end

    test "survives a merge of the target whose tree equals merge-tree", %{fx: fx, task: task} do
      merged = merge_main!(fx)

      assert {:carried, :approval, _} = BaselineCarry.carry(request(fx, task, merged))
      assert reviewed_sha(task) == merged
    end

    test "an extra commit voids it: the latch is left on the reviewed head", %{fx: fx, task: task} do
      git!(fx.origin, ["checkout", "-q", "feature"])
      extra = commit!(fx.origin, %{"lib/evil.ex" => "x\n"}, "extra")

      assert :void = BaselineCarry.carry(request(fx, task, extra))
      assert reviewed_sha(task) == fx.reviewed
    end

    test "a head with no baseline is never carried", %{fx: fx} do
      stranger = task!()
      rebased = rebase!(fx)

      assert :void = BaselineCarry.carry(request(fx, stranger, rebased))
    end
  end
end
