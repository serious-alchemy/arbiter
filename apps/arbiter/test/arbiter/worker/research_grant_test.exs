defmodule Arbiter.Worker.ResearchGrantTest do
  @moduledoc """
  bd-6ircwr: the `research_read` ticket permission — when a run is given it
  (`resolve/3`), the workspace-scoped read-only transcript snapshot that goes
  with it (`stage_transcripts/3`), and the audit row for the grant (`audit/3`).
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ResearchGrant
  alias Arbiter.Workers.Run

  @bound %{"guardrails" => %{"bindings" => %{"research_read" => %{}}}}

  defp workspace!(config) do
    Ash.create!(Workspace, %{
      name: "rg-#{System.unique_integer([:positive])}",
      prefix: "rg",
      config: config
    })
  end

  defp ticket!(ws, type, perms) do
    Ash.create!(
      Issue,
      %{title: "t", workspace_id: ws.id, issue_type: type, permissions: perms},
      context: %{guardrail_authority: :coordinator, permission_actor: "c"}
    )
  end

  defp resolve(issue, ws, role \\ :implementer), do: ResearchGrant.resolve(issue, ws, role)

  describe "resolve/3" do
    test "a declared research_read on a task ticket in an opted-in workspace is granted" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :task, ["research_read"])

      assert %{granted?: true, claims: ["research_read"], withheld: nil} = resolve(issue, ws)
    end

    test "a research-type ticket is granted too" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :research, ["research_read"])
      assert %{granted?: true} = resolve(issue, ws)
    end

    test "off by default: a workspace that binds nothing withholds it, with the reason" do
      ws = workspace!(%{})
      issue = ticket!(ws, :task, ["research_read"])

      assert %{granted?: false, claims: [], withheld: reason} = resolve(issue, ws)
      assert reason =~ "guardrails.bindings.research_read"
    end

    test "a ticket that never declared it gets nothing, even in an opted-in workspace" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :task, [])

      assert %{granted?: false, claims: [], withheld: nil} = resolve(issue, ws)
    end

    test "a PR-producing ticket type is withheld" do
      ws = workspace!(@bound)
      # The declaration itself is refused on such a ticket, so model a ticket
      # retyped after it declared the permission.
      issue = ticket!(ws, :task, ["research_read"])
      retyped = %{issue | issue_type: :feature}

      assert %{granted?: false, withheld: reason} = resolve(retyped, ws)
      assert reason =~ "task"
    end

    test "a reviewer is never given it (design §5.4)" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :task, ["research_read"])

      assert %{granted?: false, claims: [], withheld: reason} = resolve(issue, ws, :reviewer)
      assert reason =~ "reviewer"
    end

    test "an operator-grant binding keeps it pending until the operator grants it" do
      ws =
        workspace!(%{
          "guardrails" => %{"bindings" => %{"research_read" => %{"grant_by" => "operator"}}}
        })

      issue = ticket!(ws, :task, ["research_read"])

      assert Permissions.pending(issue) == ["research_read"]
      assert %{granted?: false, claims: [], withheld: reason} = resolve(issue, ws)
      assert reason =~ "pending"
    end
  end

  describe "declaring research_read" do
    @coordinator %{guardrail_authority: :coordinator, permission_actor: "c"}

    test "is refused on a PR-producing ticket at creation" do
      ws = workspace!(@bound)

      assert {:error, error} =
               Ash.create(
                 Issue,
                 %{title: "t", workspace_id: ws.id, issue_type: :feature, permissions: ["research_read"]},
                 context: @coordinator
               )

      assert Exception.message(error) =~ "research_read is only for task and research"
    end

    test "is refused when added to a PR-producing ticket later" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :bug, [])

      assert {:error, error} =
               Ash.update(issue, %{permissions: ["research_read"]}, context: @coordinator)

      assert Exception.message(error) =~ "research_read is only for task and research"
    end

    test "a worker (restricted authority) cannot set it" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :task, [])

      assert {:error, _} =
               Ash.update(issue, %{permissions: ["research_read"]},
                 context: %{guardrail_authority: :restricted, permission_actor: "w"}
               )
    end
  end

  describe "stage_transcripts/3" do
    setup do
      root = Path.join(System.tmp_dir!(), "rg-root-#{System.unique_integer([:positive])}")
      dest = Path.join(System.tmp_dir!(), "rg-dest-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      on_exit(fn ->
        File.rm_rf(root)
        File.rm_rf(dest)
      end)

      %{root: root, dest: dest}
    end

    defp run!(ws, task_id) do
      Ash.create!(Run, %{
        task_id: task_id,
        workspace_id: ws.id,
        repo: "r",
        started_at: DateTime.utc_now()
      })
    end

    defp log!(root, run, body) do
      File.write!(Path.join(root, run.id <> ".log"), body)
    end

    test "copies only this workspace's run transcripts, read-only", %{root: root, dest: dest} do
      mine = workspace!(@bound)
      other = workspace!(@bound)
      run_a = run!(mine, "bd-mine-1")
      run_b = run!(other, "bd-other-1")
      log!(root, run_a, "mine\n")
      log!(root, run_b, "SECRET of the other workspace\n")

      assert {:ok, %{dir: ^dest, count: 1}} =
               ResearchGrant.stage_transcripts(mine.id, dest, root: root)

      assert File.read!(Path.join(dest, run_a.id <> ".log")) == "mine\n"
      refute File.exists?(Path.join(dest, run_b.id <> ".log"))
      assert Bitwise.band(File.stat!(Path.join(dest, run_a.id <> ".log")).mode, 0o222) == 0
    end

    test "is a copy, not a link: writing the snapshot cannot reach the archive", %{
      root: root,
      dest: dest
    } do
      ws = workspace!(@bound)
      run = run!(ws, "bd-copy-1")
      log!(root, run, "original\n")

      {:ok, _} = ResearchGrant.stage_transcripts(ws.id, dest, root: root)
      staged = Path.join(dest, run.id <> ".log")
      File.chmod!(staged, 0o644)
      File.write!(staged, "tampered\n")

      assert File.read!(Path.join(root, run.id <> ".log")) == "original\n"
    end

    test "skips runs with no transcript on disk and honours :limit", %{root: root, dest: dest} do
      ws = workspace!(@bound)
      runs = for n <- 1..3, do: run!(ws, "bd-lim-#{n}")
      Enum.each(Enum.take(runs, 2), &log!(root, &1, "x\n"))

      assert {:ok, %{count: 1}} =
               ResearchGrant.stage_transcripts(ws.id, dest, root: root, limit: 1)
    end

    test "an absent archive root stages an empty snapshot", %{dest: dest} do
      ws = workspace!(@bound)

      assert {:ok, %{count: 0}} =
               ResearchGrant.stage_transcripts(ws.id, dest, root: "/nonexistent/arbiter-logs")

      assert File.dir?(dest)
    end
  end

  describe "audit/3" do
    test "records a granted permission_event naming the run" do
      ws = workspace!(@bound)
      issue = ticket!(ws, :task, ["research_read"])

      assert :ok = ResearchGrant.audit(issue, "run-123", transcripts: 4)

      event = issue |> Permissions.events() |> List.last()
      assert event.permission == "research_read"
      assert event.event == :granted
      assert event.source == :system
      assert event.run_id == "run-123"
      assert event.reason =~ "4 transcripts"
    end
  end
end
