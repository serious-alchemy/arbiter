defmodule Arbiter.Loop.ReplayTest do
  @moduledoc """
  bd-c7lx65 (R15, `docs/design/paced-quota-routing-signals.md` §7.2-§7.3): the
  offline replay harness end to end, with a scripted runner standing in for the
  model CLIs. It replays a closed task in an isolated checkout at its base
  commit and scores it against the known-good result; it is admitted only into
  expiring headroom, and only when every model it runs is confined; host git
  runs only in a checkout the models left as the harness made it, and the
  repo's tests only in a container; it never merges, never pushes, and writes
  nothing but its own record.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.LifecycleFixtures
  alias Arbiter.Loop.Replay
  alias Arbiter.Loop.ReplayRun
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrepushCheck
  alias Arbiter.Worker.PrivateClone

  import GitFixture, only: [git!: 2, commit!: 3]

  @now ~U[2026-10-10 01:40:27Z]
  @feature "defmodule Feature do\n  def answer, do: 42\nend\n"
  @acceptance "- lib/feature.ex defines Feature.answer/0, returning 42"

  @approve """
  VERDICT: APPROVE

  CRITERIA:
  - [MET] lib/feature.ex defines Feature.answer/0, returning 42 — lib/feature.ex:2

  arb done
  """

  @request_changes """
  VERDICT: REQUEST_CHANGES

  CRITERIA:
  - [NOT MET] lib/feature.ex defines Feature.answer/0, returning 42 — no such file

  1. [High] lib/other.ex:1 — the feature is not implemented. Fix: add lib/feature.ex.

  arb done
  """

  # The forge (`origin`): `main` at `base`; the PR branch `feature` whose head
  # adds lib/feature.ex; the PR squash-merged onto `main`. The workspace's
  # checkout of the repo has fetched it all.
  setup do
    %{root: root, origin: origin, clone: repo} =
      GitFixture.origin_and_clone(%{"README.md" => "readme\n", "lib/app.ex" => "app\n"})

    base = git!(origin, ["rev-parse", "HEAD"])
    git!(origin, ["checkout", "-q", "-b", "feature"])
    head = commit!(origin, %{"lib/feature.ex" => @feature}, "the feature")
    git!(origin, ["checkout", "-q", "main"])
    commit!(origin, %{"lib/feature.ex" => @feature}, "Add the feature (#7)")
    git!(repo, ["fetch", "-q", "origin"])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "replay-#{System.unique_integer([:positive])}",
        config: %{
          "repo_paths" => %{"app" => repo},
          "worker" => %{
            "repos" => %{
              "app" => %{
                "pre_push_checks" => [
                  %{"name" => "tests", "cmd" => "test -f lib/feature.ex", "timeout_s" => 30}
                ]
              }
            }
          }
        }
      })

    claude = account!(ws, :claude)
    codex = account!(ws, :codex)

    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Add the feature",
        description: "Feature.answer/0 should return 42.",
        acceptance: @acceptance,
        difficulty: 2,
        workspace_id: ws.id,
        repo: "app"
      })

    issue = LifecycleFixtures.put_state!(issue, :closed)

    Repo.query!("UPDATE issues SET merger_status = ?2 WHERE id = ?1", [
      issue.id,
      Jason.encode!(%{"head_sha" => head, "status" => "merged"})
    ])

    %{
      root: root,
      origin: origin,
      repo: repo,
      base: base,
      head: head,
      ws: ws,
      claude: claude,
      codex: codex,
      issue: Ash.get!(Issue, issue.id),
      replays: Path.join(root, "replays")
    }
  end

  defp account!(ws, provider) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: provider,
        slug: "#{provider}-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id
    })

    account
  end

  # ---- budgets ------------------------------------------------------------------

  defp snapshot(used_5h, used_7d, reset_5h, reset_7d) do
    %Snapshot{
      provider: "claude",
      utilization: used_5h,
      status: "allowed",
      reset_at: reset_5h,
      captured_at: @now,
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: used_7d,
      secondary_status: "allowed",
      secondary_reset_at: reset_7d,
      secondary_window_label: "7d"
    }
  end

  defp policy(max_concurrent),
    do: %ProviderAccount{
      provider: :claude,
      quota_config: %{"threshold_mode" => "paced"},
      max_concurrent: max_concurrent
    }

  # Quota that would reset unused: `explore/2` is 2.
  defp quiet do
    Budget.compute(
      account: policy(nil),
      pool: "claude",
      quota: snapshot(0.10, 0.10, DateTime.add(@now, 5 * 3600), DateTime.add(@now, 3 * 86_400)),
      now: @now,
      seats: 0,
      horizon: 2.0
    )
  end

  # Quota near its line, three seats running: `explore/2` is 0.
  defp busy do
    Budget.compute(
      account: policy(3),
      pool: "claude",
      quota: snapshot(0.19, 0.49, ~U[2026-10-10 04:40:00Z], ~U[2026-10-12 16:00:00Z]),
      now: @now,
      seats: 3,
      horizon: 2.0
    )
  end

  # ---- the scripted runner --------------------------------------------------------

  defp result(lines) do
    {:ok,
     %{
       output: lines,
       exit_status: 0,
       timed_out: false,
       duration_ms: 5,
       usage: %{tokens_in: 100, tokens_out: 20}
     }}
  end

  defp write_feature(spec) do
    commit!(spec.dir, %{"lib/feature.ex" => @feature}, "implement the feature")
    result(["implemented", "arb done"])
  end

  defp runner(test, opts \\ []) do
    implement = Keyword.get(opts, :implement, &write_feature/1)
    verdict = Keyword.get(opts, :verdict, @approve)
    review = Keyword.get(opts, :review, fn _spec -> result(String.split(verdict, "\n")) end)
    tests = Keyword.get(opts, :tests, &tests_in_place/1)

    fn
      :implement, spec ->
        send(test, {:implement, observe(spec)})
        implement.(spec)

      :review, spec ->
        send(test, {:review, spec})
        review.(spec)

      :test, spec ->
        send(test, {:test, spec})
        tests.(spec)
    end
  end

  # Stands in for the runner's container: the recipe, run in the checkout.
  defp tests_in_place(spec),
    do: {:ok, PrepushCheck.run_steps(spec.recipe, spec.dir, target: spec.base_sha)}

  defp observe(spec) do
    %{
      spec: spec,
      head: git!(spec.dir, ["rev-parse", "HEAD"]),
      feature?: File.exists?(Path.join(spec.dir, "lib/feature.ex")),
      remotes: git!(spec.dir, ["remote"]),
      refs: git!(spec.dir, ["for-each-ref", "--format=%(refname)"])
    }
  end

  defp no_spend,
    do: fn role, _spec -> flunk("the #{role} run spent quota it was not admitted for") end

  defp replay(ctx, opts \\ []) do
    [
      task_id: ctx.issue.id,
      account: ctx.claude.id,
      model: "claude-sonnet-5-5",
      reviewer: ctx.codex.id,
      reviewer_model: "gpt-5.5-codex",
      root: ctx.replays,
      now: @now,
      budget_fun: fn _account_id, _pool -> quiet() end,
      runner: runner(self())
    ]
    |> Keyword.merge(opts)
    |> Replay.run()
  end

  defp running!(ctx, account_id, pool, started_at, deadline_at \\ nil) do
    Ash.create!(ReplayRun, %{
      task_id: ctx.issue.id,
      workspace_id: ctx.ws.id,
      repo: "app",
      provider: "claude",
      account_id: account_id,
      model: "claude-sonnet-5-5",
      pool: pool,
      state: :running,
      started_at: started_at,
      deadline_at: deadline_at || DateTime.add(started_at, 2 * 3600)
    })
  end

  defp recipe!(ctx, cmd) do
    config =
      put_in(ctx.ws.config, ["worker", "repos", "app", "pre_push_checks"], [
        %{"name" => "tests", "cmd" => cmd, "timeout_s" => 30}
      ])

    %{ctx | ws: Ash.update!(ctx.ws, %{config: config})}
  end

  # A replay that leaves `key = value` in its checkout's git config.
  defp configures(key, value) do
    fn spec ->
      done = write_feature(spec)
      git!(spec.dir, ["config", key, value])
      done
    end
  end

  defp refs(repo), do: git!(repo, ["for-each-ref", "--format=%(refname) %(objectname)"])

  defp row(table, id) do
    %{rows: rows, columns: columns} = Repo.query!("SELECT * FROM #{table} WHERE id = ?1", [id])
    Enum.map(rows, &Enum.zip(columns, &1))
  end

  defp counts do
    for table <-
          ~w(worker_runs review_gate_rounds usage_events ticket_transitions loop_pending_writes),
        into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT COUNT(*) FROM #{table}")
      {table, n}
    end
  end

  defp settings do
    %{rows: rows} = Repo.query!("SELECT * FROM installation_settings")
    rows
  end

  # ---- the replay ----------------------------------------------------------------

  describe "run/1 replays a closed task and scores it against the known-good result" do
    test "in an isolated checkout at the task's base commit, with the merged change out of reach",
         ctx do
      assert {:ok, %ReplayRun{} = run} = replay(ctx)

      assert_received {:implement, seen}
      assert seen.head == ctx.base
      refute seen.feature?
      assert seen.remotes == ""
      assert seen.refs == "refs/heads/work"
      assert seen.spec.dir != ctx.repo
      assert seen.spec.model == "claude-sonnet-5-5"
      assert seen.spec.account_id == ctx.claude.id
      assert seen.spec.provider == :claude
      assert seen.spec.prompt =~ "Feature.answer/0 should return 42."
      assert seen.spec.prompt =~ @acceptance

      refute File.exists?(Path.join(ctx.replays, run.id)), "the sandbox is removed"
    end

    test "the score: the scoring reviewer's round-1 verdict, the repo's tests, the overlap",
         ctx do
      assert {:ok, run} = replay(ctx)

      assert_received {:review, review}
      assert review.model == "gpt-5.5-codex"
      assert review.account_id == ctx.codex.id
      assert review.provider == :codex
      assert review.prompt =~ @acceptance
      assert review.prompt =~ "git diff #{ctx.base}..HEAD"
      refute review.prompt =~ "gh pr", "the reviewer is never pointed at the merged PR"

      run = Ash.get!(ReplayRun, run.id)
      assert run.state == :scored
      assert run.verdict == :approve
      assert run.converged == true
      assert {run.criteria_total, run.criteria_unmet} == {1, 0}
      # On the host the repo's tests never run: they would run the replayed code.
      assert run.tests == :not_run
      refute_received {:test, _}
      assert run.file_overlap == 1.0
      assert run.line_overlap == 1.0
      assert run.files == ["lib/feature.ex"]

      # What each side drew is on the replay's own record, never a usage event.
      for side <- ["implement", "review"] do
        assert %{"usage" => %{"tokens_in" => 100, "tokens_out" => 20}} = run.runs[side]
      end

      assert run.task_id == ctx.issue.id
      assert run.base_sha == ctx.base
      assert run.known_good_sha == ctx.head
      assert run.provenance == :pr_head

      assert {run.provider, run.account_id, run.model, run.pool} ==
               {"claude", ctx.claude.id, "claude-sonnet-5-5", "claude"}

      assert {run.reviewer_provider, run.reviewer_account_id, run.reviewer_model,
              run.reviewer_pool} ==
               {"codex", ctx.codex.id, "gpt-5.5-codex", "codex"}

      assert {run.difficulty, run.issue_type} == {2, "feature"}
      assert run.finished_at

      assert [%{"pool" => "claude", "admitted" => true}, %{"pool" => "codex", "admitted" => true}] =
               run.admission
    end

    test "a replay that misses the criteria does not converge, and overlaps less", ctx do
      implement = fn spec ->
        commit!(spec.dir, %{"lib/other.ex" => "defmodule Other do\nend\n"}, "something else")
        result(["arb done"])
      end

      assert {:ok, run} =
               replay(ctx,
                 layout: :private_clone,
                 runner: runner(self(), implement: implement, verdict: @request_changes)
               )

      assert run.state == :scored
      assert run.verdict == :request_changes
      assert run.converged == false
      assert {run.criteria_total, run.criteria_unmet} == {1, 1}
      assert run.tests == :failed
      assert run.file_overlap == 0.0
    end

    test "uncommitted work is reviewed, but an APPROVE of it cannot converge (empty net diff)",
         ctx do
      implement = fn spec ->
        File.mkdir_p!(Path.join(spec.dir, "lib"))
        File.write!(Path.join(spec.dir, "lib/feature.ex"), @feature)
        result(["arb done"])
      end

      assert {:ok, run} = replay(ctx, runner: runner(self(), implement: implement))

      assert_received {:review, _}
      assert run.verdict == :approve
      assert run.converged == false
      assert run.file_overlap == 1.0
    end

    test "a replay that changed nothing is scored without spending a review", ctx do
      assert {:ok, run} = replay(ctx, runner: runner(self(), implement: fn _ -> result([]) end))

      refute_received {:review, _}
      assert run.state == :scored
      assert run.converged == false
      assert run.verdict == nil
      assert run.reason =~ "no change"
      assert run.file_overlap == 0.0
    end

    test "each side runs at the thinking level a dispatch would give it", ctx do
      config =
        ctx.ws.config
        |> Map.put("routing", %{
          "policy" => "by_difficulty",
          "rules" => %{"D2" => %{"model_tier" => "standard", "thinking" => "high"}}
        })
        |> Map.put("review_agent", %{"config" => %{"thinking" => "medium"}})

      ctx = %{ctx | ws: Ash.update!(ctx.ws, %{config: config})}

      assert {:ok, run} = replay(ctx)

      assert_received {:implement, %{spec: %{thinking: "high"}}}
      assert_received {:review, %{thinking: "medium"}}
      assert {run.thinking, run.reviewer_thinking} == {"high", "medium"}
    end

    test "an explicit thinking level wins, for either side", ctx do
      assert {:ok, run} = replay(ctx, thinking: "max", reviewer_thinking: "low")

      assert_received {:implement, %{spec: %{thinking: "max"}}}
      assert_received {:review, %{thinking: "low"}}
      assert {run.thinking, run.reviewer_thinking} == {"max", "low"}
    end

    test "the default scoring reviewer is the one the fleet would use", ctx do
      assert {:ok, run} = replay(ctx, reviewer: nil, reviewer_model: nil)

      # Cross-family review is off here, so the workspace's reviewer: Claude,
      # on the workspace's Claude account, one seat on the one pool.
      assert run.reviewer_provider == "claude"
      assert run.reviewer_account_id == ctx.claude.id
      assert run.reviewer_pool == "claude"
      assert is_binary(run.reviewer_model)
      assert [%{"admitted" => true, "pool" => "claude"}] = run.admission
    end
  end

  describe "a run a container is handed (layout :private_clone)" do
    test "gets a read-only private clone at the base, whose origin leads nowhere, removed after",
         ctx do
      main_refs = refs(ctx.repo)
      test_pid = self()

      implement = fn spec ->
        send(test_pid, {:clone, PrivateClone.clone?(spec.dir), PrivateClone.read_only?(spec.dir)})
        send(test_pid, {:reachable, git!(spec.dir, ["log", "--all", "--format=%H"])})

        {_, fetch} =
          System.cmd("git", ["-C", spec.dir, "fetch", "-q", "origin"], stderr_to_stdout: true)

        send(test_pid, {:fetch_status, fetch})
        write_feature(spec)
      end

      assert {:ok, run} =
               replay(ctx, layout: :private_clone, runner: runner(self(), implement: implement))

      assert_received {:implement, seen}
      assert seen.head == ctx.base
      refute seen.feature?
      assert Path.dirname(seen.spec.dir) == Arbiter.Config.Paths.worktree_root()
      assert_received {:clone, true, true}
      assert_received {:reachable, reachable}
      refute reachable =~ ctx.head, "nothing after the base is reachable in the clone"
      assert_received {:fetch_status, status} when status != 0

      assert_received {:review, review}
      assert review.prompt =~ "git diff #{ctx.base}..HEAD"

      assert run.state == :scored
      assert run.converged
      assert run.file_overlap == 1.0
      refute File.exists?(seen.spec.dir)
      assert refs(ctx.repo) == main_refs, "the clone's gc pin is dropped with it"
    end

    test "is seeded before the model runs; nothing the model leaves in it runs on the host",
         ctx do
      # The main checkout's fetched dependencies (ignored there, as deps/ is).
      File.mkdir_p!(Path.join(ctx.repo, "deps/somedep"))
      File.write!(Path.join(ctx.repo, "deps/somedep/mix.exs"), "seeded\n")
      File.write!(Path.join(ctx.repo, ".git/info/exclude"), "/deps\n", [:append])
      marker = Path.join(ctx.root, "mix-exs-ran-on-host")
      outside = Path.join(ctx.root, "outside")
      File.mkdir_p!(outside)
      test_pid = self()

      implement = fn spec ->
        send(test_pid, {:seeded, File.read(Path.join(spec.dir, "deps/somedep/mix.exs"))})

        # A mix.exs that runs code when mix loads it, and deps/ pointed at a
        # directory outside the checkout.
        File.rm_rf!(Path.join(spec.dir, "deps"))
        File.ln_s!(outside, Path.join(spec.dir, "deps"))

        commit!(
          spec.dir,
          %{"lib/feature.ex" => @feature, "mix.exs" => "File.touch!(#{inspect(marker)})\n"},
          "the feature"
        )

        result(["arb done"])
      end

      assert {:ok, run} =
               replay(ctx, layout: :private_clone, runner: runner(self(), implement: implement))

      assert_received {:seeded, {:ok, "seeded\n"}}
      assert run.state == :scored
      assert run.files == ["lib/feature.ex", "mix.exs"]
      refute File.exists?(marker)
      assert File.ls!(outside) == []
    end
  end

  describe "the repo's tests run the replayed model's code, so only ever in a container" do
    test "in its container, through the runner: the recipe, in the replay's checkout, at the base",
         ctx do
      assert {:ok, run} = replay(ctx, layout: :private_clone)

      assert_received {:implement, seen}
      assert_received {:test, spec}
      assert spec.dir == seen.spec.dir
      assert spec.base_sha == ctx.base
      assert {spec.provider, spec.model} == {:claude, "claude-sonnet-5-5"}
      assert [%{name: "tests"}] = spec.recipe.steps

      assert run.tests == :passed
      assert %{"steps" => [%{"name" => "tests", "status" => "passed"}]} = run.runs["tests"]
    end

    test "on the host, never", ctx do
      marker = Path.join(ctx.root, "tests-ran-on-host")
      ctx = recipe!(ctx, "sh ./check.sh")

      implement = fn spec ->
        commit!(
          spec.dir,
          %{"lib/feature.ex" => @feature, "check.sh" => "touch #{marker}\n"},
          "the feature, and a check"
        )

        result(["arb done"])
      end

      assert {:ok, run} = replay(ctx, runner: runner(self(), implement: implement))

      refute_received {:test, _}
      refute File.exists?(marker)
      assert run.state == :scored
      assert run.tests == :not_run
    end

    test "a runner that cannot run them: :error, and why", ctx do
      runner = runner(self(), tests: fn _spec -> {:error, :no_image} end)

      assert {:ok, run} = replay(ctx, layout: :private_clone, runner: runner)

      assert run.state == :scored
      assert run.tests == :error
      assert run.runs["tests"]["error"] =~ "no_image"
    end

    test "tests: false, or no recipe: not run", ctx do
      assert {:ok, %{tests: :not_run}} = replay(ctx, layout: :private_clone, tests: false)
      refute_received {:test, _}
    end
  end

  describe "every model a replay runs is confined, or it is refused before admission" do
    test "a side the runner cannot confine: no record, no checkout, nothing spent", ctx do
      assert {:error, {:unconfined, :review, :codex}} =
               replay(ctx, runner: Arbiter.Test.UnconfinedReplayRunner)

      # Each side is asked, before there is a replay or a checkout.
      assert_received {:layout, :implement,
                       %{provider: :claude, model: "claude-sonnet-5-5", replay_id: nil, dir: nil}}

      assert_received {:layout, :review, %{provider: :codex, model: "gpt-5.5-codex"}}
      assert Ash.read!(ReplayRun) == []
      refute File.exists?(ctx.replays)
    end

    test "a runner whose layout raises is refused the same way: no record, none left running",
         ctx do
      assert {:error, {:layout_failed, message}} =
               replay(ctx, runner: Arbiter.Test.RaisingReplayRunner)

      assert message =~ "layout exploded"
      assert Ash.read!(ReplayRun) == []
    end
  end

  describe "host git runs only in a checkout the replay left as the harness made it" do
    setup ctx do
      marker = Path.join(ctx.root, "repo-config-ran")
      script = Path.join(ctx.root, "evil.sh")
      File.write!(script, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(script, 0o755)
      %{marker: marker, script: script}
    end

    test "a replay that wrote its checkout's git config is failed, untested and unreviewed",
         ctx do
      for layout <- [:sandbox, :private_clone] do
        implement = configures("core.fsmonitor", ctx.script)

        assert {:failed, run} =
                 replay(ctx, layout: layout, runner: runner(self(), implement: implement))

        assert run.reason =~ "tampered", "#{layout}"
        refute_received {:test, _}
        refute_received {:review, _}
        refute File.exists?(ctx.marker)
        refute File.exists?(Path.join(ctx.replays, run.id))
      end
    end

    test "a clone whose markers were rewritten is failed, and nothing of it reaches the main repo",
         ctx do
      main_refs = refs(ctx.repo)

      # Markers that would make `PrivateClone.remove/1` carry a branch of the
      # model's choosing into the main repo.
      implement = fn spec ->
        done = write_feature(spec)
        git!(spec.dir, ["branch", "smuggled", "HEAD"])
        git!(spec.dir, ["config", "--unset", "arbiter.readOnly"])
        git!(spec.dir, ["config", "arbiter.branch", "smuggled"])
        done
      end

      assert {:failed, run} =
               replay(ctx, layout: :private_clone, runner: runner(self(), implement: implement))

      assert run.reason =~ "tampered"
      refute_received {:review, _}
      assert refs(ctx.repo) == main_refs
      refute File.exists?(Path.join(Arbiter.Config.Paths.worktree_root(), "replay-" <> run.id))
    end

    test "so is one the scoring reviewer tampered with", ctx do
      review = fn spec ->
        git!(spec.dir, ["config", "core.fsmonitor", ctx.script])
        result(String.split(@approve, "\n"))
      end

      assert {:failed, run} = replay(ctx, runner: runner(self(), review: review))

      assert run.reason =~ "tampered"
      assert run.converged == nil
      refute File.exists?(ctx.marker)
    end
  end

  describe "spend restricted to expiring headroom" do
    test "no expiring headroom: refused before anything runs or any checkout is made", ctx do
      assert {:refused, run} = replay(ctx, runner: no_spend(), budget_fun: fn _, _ -> busy() end)

      assert run.state == :refused
      assert run.reason =~ "no expiring headroom"
      assert [%{"admitted" => false, "explore" => 0} | _] = run.admission
      refute File.exists?(ctx.replays)
    end

    test "nothing published (not the live node): refused", ctx do
      assert {:refused, run} = replay(ctx, runner: no_spend(), budget_fun: fn _, _ -> nil end)
      assert run.reason =~ "no published budget"
    end

    test "the scoring reviewer's pool needs expiring headroom too", ctx do
      budget_fun = fn
        _account_id, "codex" -> busy()
        _account_id, _pool -> quiet()
      end

      assert {:refused, run} = replay(ctx, runner: no_spend(), budget_fun: budget_fun)
      assert run.reason =~ "/codex"
    end

    test "replays already running on the pool take its exploration budget", ctx do
      running!(ctx, ctx.claude.id, "claude", @now)
      running!(ctx, ctx.claude.id, "claude", @now)

      assert {:refused, run} = replay(ctx, runner: no_spend())
      assert run.reason =~ "2 replays running"
    end

    test "a replay left running long ago (a crashed node) no longer holds a seat", ctx do
      running!(ctx, ctx.claude.id, "claude", DateTime.add(@now, -2 * 86_400))
      running!(ctx, ctx.claude.id, "claude", DateTime.add(@now, -2 * 86_400))

      assert {:ok, %{state: :scored}} = replay(ctx)
    end

    test "a replay holds its seats until its own deadline, however long that is", ctx do
      started = DateTime.add(@now, -8 * 3600)
      running!(ctx, ctx.claude.id, "claude", started, DateTime.add(@now, 2 * 3600))
      running!(ctx, ctx.claude.id, "claude", started, DateTime.add(@now, 2 * 3600))

      assert {:refused, run} = replay(ctx, runner: no_spend())
      assert run.reason =~ "2 replays running"
    end

    test "past its deadline it holds none, however recently it started", ctx do
      started = DateTime.add(@now, -60)
      one = running!(ctx, ctx.claude.id, "claude", started, DateTime.add(@now, -1))
      running!(ctx, ctx.claude.id, "claude", started, DateTime.add(@now, -1))

      assert {:ok, %{state: :scored}} = replay(ctx)
      assert %{state: :failed, reason: reason} = Ash.get!(ReplayRun, one.id)
      assert reason =~ "deadline"
    end

    test "its deadline covers both runs' timeouts, set when it is admitted", ctx do
      assert {:ok, run} =
               replay(ctx, timeout_ms: 10 * 3_600_000, review_timeout_ms: 3_600_000)

      assert DateTime.compare(run.started_at, @now) == :eq
      assert DateTime.diff(run.deadline_at, @now) >= 11 * 3600
    end

    test "the reviewer's pool is checked again before the scoring review spends", ctx do
      spent = :counters.new(1, [])

      budget_fun = fn
        _account_id, "codex" -> if :counters.get(spent, 1) == 0, do: quiet(), else: busy()
        _account_id, _pool -> quiet()
      end

      implement = fn spec ->
        :counters.add(spent, 1, 1)
        write_feature(spec)
      end

      assert {:ok, run} =
               replay(ctx, budget_fun: budget_fun, runner: runner(self(), implement: implement))

      refute_received {:review, _}
      assert run.state == :unscored
      assert run.converged == nil
      assert run.reason =~ "/codex"
      assert run.file_overlap == 1.0
    end
  end

  describe "it never merges and never touches production" do
    test "the checkout, its remote, the ticket and every live table are as they were", ctx do
      main_refs = refs(ctx.repo)
      origin_refs = refs(ctx.origin)
      ticket = row("issues", ctx.issue.id)
      before = counts()
      installation = settings()

      assert {:ok, %{state: :scored}} = replay(ctx)

      assert refs(ctx.repo) == main_refs
      assert refs(ctx.origin) == origin_refs
      assert git!(ctx.repo, ["status", "--porcelain"]) == ""
      assert row("issues", ctx.issue.id) == ticket
      assert counts() == before
      assert settings() == installation
    end
  end

  describe "the leftovers of a replay whose node died" do
    test "are swept by the next replay; a live replay's checkout is left alone", ctx do
      main_refs = refs(ctx.repo)
      stale = running!(ctx, ctx.claude.id, "claude", DateTime.add(@now, -2 * 86_400))
      leftover = Path.join(ctx.replays, stale.id)
      File.mkdir_p!(Path.join(leftover, "checkout"))

      leaf = Path.join(Arbiter.Config.Paths.worktree_root(), "replay-" <> stale.id)
      {:ok, _} = PrivateClone.create_review(ctx.repo, ctx.base, path: leaf)

      live = running!(ctx, ctx.claude.id, "claude", @now)
      kept = Path.join(ctx.replays, live.id)
      File.mkdir_p!(kept)

      assert {:ok, %{state: :scored}} = replay(ctx)

      refute File.exists?(leftover)
      refute File.exists?(leaf)
      assert refs(ctx.repo) == main_refs, "the dead clone's gc pin is dropped too"
      assert File.exists?(kept)

      assert %{state: :failed, reason: reason, finished_at: %DateTime{}} =
               Ash.get!(ReplayRun, stale.id)

      assert reason =~ "abandoned"
      assert Ash.get!(ReplayRun, live.id).state == :running
    end
  end

  describe "failures" do
    test "a run that fails is recorded as failed, and its sandbox is still removed", ctx do
      runner = fn
        :implement, _spec -> {:error, :cli_missing}
        :review, _spec -> flunk("no review after a failed run")
      end

      assert {:failed, run} = replay(ctx, runner: runner)
      assert run.state == :failed
      assert run.reason =~ "cli_missing"
      assert run.finished_at
      refute File.exists?(Path.join(ctx.replays, run.id))
    end

    test "a runner that raises is recorded as failed too", ctx do
      runner = fn _role, _spec -> raise "boom" end

      assert {:failed, run} = replay(ctx, runner: runner)
      assert run.reason =~ "boom"
      refute File.exists?(Path.join(ctx.replays, run.id))
    end

    test "an ineligible task is refused with no record", ctx do
      Repo.query!("UPDATE issues SET permissions = ?2 WHERE id = ?1", [
        ctx.issue.id,
        ~s(["prod_ssh"])
      ])

      assert {:error, {:permissions, ["prod_ssh"]}} = replay(ctx, runner: no_spend())
      assert Ash.read!(ReplayRun) == []
    end

    test "an account the task's workspace is not attached to is refused", ctx do
      loose =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "loose-#{System.unique_integer([:positive])}"
        })

      assert {:error, {:account_not_in_workspace, _}} =
               replay(ctx, account: loose.id, runner: no_spend())
    end

    test "an unknown account is refused", ctx do
      assert {:error, {:unknown_account, "nobody"}} =
               replay(ctx, account: "nobody", runner: no_spend())
    end

    test "with no runner given, the configured one; tests configure none, so nothing spawns",
         ctx do
      assert {:error, :runner_disabled} =
               Replay.run(
                 task_id: ctx.issue.id,
                 account: ctx.claude.id,
                 model: "claude-sonnet-5-5",
                 budget_fun: fn _, _ -> quiet() end,
                 root: ctx.replays,
                 now: @now
               )

      assert Ash.read!(ReplayRun) == []
    end
  end
end
