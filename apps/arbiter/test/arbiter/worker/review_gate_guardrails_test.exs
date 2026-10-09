defmodule Arbiter.Worker.ReviewGateGuardrailsTest do
  @moduledoc """
  bd-atll60 (G13): the ReviewGate's reviewer pass is gated by the guardrails on
  every path that names a reviewer — cross-family routing (`ReviewerRouting`)
  and the ordinary first-choice resolution of a workspace with cross-family
  review off (`docs/design/guardrail-profiles.md` §5.4, §5.7).

  Drives the REAL adapter spawn path with `agy` and `claude` stubbed onto `PATH`,
  as `ReviewGateCrossFamilyTest` does.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  # ---- stubs / scaffolding (as in ReviewGateCrossFamilyTest) -------------------

  defp stub_approve(dir, name, log) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    echo "#{name}" >> #{log}
    echo "reviewing the diff..."
    echo "VERDICT: APPROVE"
    echo "findings: the change looks consistent with the acceptance criteria"
    echo "arb done"
    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp prepend_path(dir) do
    old = System.get_env("PATH") || ""
    System.put_env("PATH", "#{dir}:#{old}")
    on_exit(fn -> System.put_env("PATH", old) end)
  end

  defp calls(log) do
    case File.read(log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "#{String.replace(branch, "/", "-")}.txt"), "worker work\n")
    {_, 0} = git(["add", "."], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(20) && do_wait(fun, deadline)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-guard-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn ->
      File.rm_rf!(tmp)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    log = Path.join(tmp, "reviewer-calls.txt")
    stub_approve(stub_dir, "agy", log)
    stub_approve(stub_dir, "claude", log)
    prepend_path(stub_dir)

    %{repo: repo, log: log}
  end

  defp guard!(rules), do: put_app_env(:arbiter, :guardrail_subject_rules, rules)

  defp workspace(types, cross_family) do
    Ash.create!(Workspace, %{
      name: "rgg-ws-#{System.unique_integer([:positive])}",
      prefix: "rg",
      config: %{
        "review" => %{"required" => true, "rounds" => 1},
        "review_agent" => %{"type" => types, "cross_family" => cross_family}
      }
    })
  end

  defp new_task(ws, implementer \\ "claude") do
    task =
      ws
      |> then(&Ash.create!(Issue, %{title: "guarded review", workspace_id: &1.id, difficulty: 1}))
      |> put_state!(:active)
      |> Ash.Changeset.for_update(:pin_implementer, %{implementer_family: "anthropic"})
      |> Ash.update!()

    Ash.create!(Run, %{
      task_id: task.id,
      base_task_id: task.id,
      repo: "trib/repo",
      kind: :implement,
      provider: implementer,
      started_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    task
  end

  defp run_gate(task, repo, branch) do
    :ok = seed_feature_branch(repo, branch)

    meta = %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_rounds: 1,
      worktree_path: repo,
      review_verdict_retries: 0,
      review_timeout_ms: 30_000
    }

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    pid
  end

  defp review_rounds(task_id) do
    require Ash.Query

    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  # Claude implements (privileged). agy is quarantined: it may not review at all.
  @agy_cannot_review [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "antigravity"}, tier: :quarantine}
  ]

  test "cross-family: an ineligible other family falls back to the implementer's own, recorded",
       %{repo: repo, log: log} do
    guard!(@agy_cannot_review)
    ws = workspace(["gemini", "claude"], true)
    task = new_task(ws)

    run_gate(task, repo, "feature/rgg-fallback")
    wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

    assert calls(log) == ["claude"]
    assert [round] = review_rounds(task.id)
    assert round.same_family_fallback == true
    assert round.same_family_fallback_reason =~ "guardrail_ineligible"
  end

  test "cross-family with same_family_fallback: hold: no reviewer is started", %{
    repo: repo,
    log: log
  } do
    guard!([
      %{
        match: %{provider: "claude"},
        tier: :privileged,
        overrides: %{review: %{same_family_fallback: :hold}}
      },
      %{match: %{provider: "antigravity"}, tier: :quarantine}
    ])

    ws = workspace(["gemini", "claude"], true)
    task = new_task(ws)

    run_gate(task, repo, "feature/rgg-hold")

    wait_until(fn -> Ash.get!(Issue, task.id).attention_cause != nil end, 10_000)
    assert calls(log) == []
    assert merge_commit_count(repo) == 0

    assert review_rounds(task.id) == [] or
             Enum.all?(review_rounds(task.id), &(&1.verdict != :approve))
  end

  test "cross-family off: the first-choice reviewer is still gated as a reviewer subject", %{
    repo: repo,
    log: log
  } do
    # claude would review first; as a quarantined subject it may not review at all.
    # The implementer (codex, privileged) imposes no cross-family requirement, so
    # this is the ordinary first-choice resolution.
    guard!([
      %{match: %{provider: "codex"}, tier: :privileged},
      %{match: %{provider: "claude"}, tier: :quarantine},
      %{match: %{provider: "antigravity"}, tier: :privileged}
    ])

    ws = workspace(["claude", "gemini"], false)
    task = new_task(ws, "codex")

    run_gate(task, repo, "feature/rgg-legacy")

    wait_until(fn -> Ash.get!(Issue, task.id).attention_cause != nil end, 10_000)
    assert calls(log) == []
    assert merge_commit_count(repo) == 0
  end
end
