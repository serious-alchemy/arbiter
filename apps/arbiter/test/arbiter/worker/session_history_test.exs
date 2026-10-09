defmodule Arbiter.Worker.SessionHistoryTest do
  # async: false — swaps the :output_log_root application env.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker.SessionArchive
  alias Arbiter.Worker.SessionHistory
  alias Arbiter.Workers.Run

  @sid "ead93203-0505-4188-8e74-125d64ac68dc"
  @cwd "/work/tree/clone"

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    base = Path.join(System.tmp_dir!(), "session-history-#{System.unique_integer([:positive])}")
    Application.put_env(:arbiter, :output_log_root, Path.join(base, "logs"))

    on_exit(fn ->
      File.rm_rf(base)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    %{base: base, new_config: Path.join(base, "new-config")}
  end

  defp create_run(config_dir, task_id \\ nil) do
    {:ok, run} =
      Ash.create(Run, %{
        task_id: task_id || "bd-hist#{System.unique_integer([:positive])}",
        task_title: "t",
        repo: "r/r",
        state: :finished,
        outcome: :failed,
        started_at: DateTime.utc_now(),
        session_id: @sid,
        config_dir: config_dir,
        provider: "claude"
      })

    run
  end

  defp jsonl_path(config_dir, slug),
    do: Path.join([config_dir, "projects", slug, @sid <> ".jsonl"])

  test "resume_session_id/1 reads the sid after --resume" do
    assert SessionHistory.resume_session_id(["claude", "--print", "--resume", @sid, "go"]) == @sid
    assert SessionHistory.resume_session_id(["claude", "--print", "go"]) == nil
    assert SessionHistory.resume_session_id(nil) == nil
  end

  test "not found when no run or archive holds the session", %{new_config: new} do
    refute SessionHistory.available?(@sid)
    assert {:error, :not_found} = SessionHistory.seed(new, @cwd, @sid)
  end

  test "seeds only that session from the prior run's config dir", %{base: base, new_config: new} do
    prior = Path.join(base, "prior-config")
    File.mkdir_p!(Path.dirname(jsonl_path(prior, "-old")))
    File.write!(jsonl_path(prior, "-old"), "{\"a\":1}\n")
    File.write!(Path.join(prior, ".credentials.json"), "secret")
    create_run(prior)

    assert SessionHistory.available?(@sid)
    assert :ok = SessionHistory.seed(new, @cwd, @sid)

    dest = jsonl_path(new, Arbiter.Usage.ClaudeSessionFile.project_slug(@cwd))
    assert File.read!(dest) == "{\"a\":1}\n"
    refute File.exists?(Path.join(new, ".credentials.json"))
  end

  test "falls back to the run archive when the config dir is gone", %{base: base, new_config: new} do
    gone = Path.join(base, "gone-config")
    run = create_run(gone)
    File.mkdir_p!(Path.dirname(SessionArchive.path_for(run.id)))
    File.write!(SessionArchive.path_for(run.id), :zlib.gzip("{\"b\":2}\n"))

    assert SessionHistory.available?(@sid)
    assert :ok = SessionHistory.seed(new, @cwd, @sid)

    dest = jsonl_path(new, Arbiter.Usage.ClaudeSessionFile.project_slug(@cwd))
    assert File.read!(dest) == "{\"b\":2}\n"
  end

  describe "preserve/1 (bd-9qazat: container removal must not lose the session)" do
    defp run_tmp_with_session(root, body) do
      tmp = Path.join(root, "run-tmp-#{System.unique_integer([:positive])}")
      config = Path.join(tmp, "claude-config")
      File.mkdir_p!(Path.dirname(jsonl_path(config, "-slug")))
      File.write!(jsonl_path(config, "-slug"), body)
      File.write!(Path.join(config, ".credentials.json"), "secret")
      tmp
    end

    test "keeps the JSONL host-side so resume works once the run tmp is gone", %{
      base: base,
      new_config: new
    } do
      tmp = run_tmp_with_session(base, "{\"c\":3}\n")

      assert [@sid] = SessionHistory.preserve(tmp)
      assert File.read!(SessionHistory.store_path(@sid)) == "{\"c\":3}\n"
      assert File.ls!(SessionHistory.store_dir()) == [@sid <> ".jsonl"]

      File.rm_rf!(tmp)

      assert SessionHistory.available?(@sid)
      assert :ok = SessionHistory.seed(new, @cwd, @sid)
      dest = jsonl_path(new, Arbiter.Usage.ClaudeSessionFile.project_slug(@cwd))
      assert File.read!(dest) == "{\"c\":3}\n"
    end

    test "a stale, shorter copy never replaces a longer stored entry", %{base: base} do
      newer = run_tmp_with_session(base, "{\"n\":1}\n{\"n\":2}\n")
      stale = run_tmp_with_session(base, "{\"n\":1}\n")

      assert [@sid] = SessionHistory.preserve(newer)
      assert [] = SessionHistory.preserve(stale)
      assert File.read!(SessionHistory.store_path(@sid)) == "{\"n\":1}\n{\"n\":2}\n"
      assert File.ls!(SessionHistory.store_dir()) == [@sid <> ".jsonl"]

      longer = run_tmp_with_session(base, "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
      assert [@sid] = SessionHistory.preserve(longer)
      assert File.read!(SessionHistory.store_path(@sid)) =~ ~s({"n":3})
    end

    test "RunTmp.remove/1 preserves before deleting" do
      root = Arbiter.Config.Paths.worker_tmp_root()
      File.mkdir_p!(root)
      inside = run_tmp_with_session(root, "{\"d\":4}\n")

      assert :ok = Arbiter.Worker.RunTmp.remove(inside)
      refute File.exists?(inside)
      assert File.read!(SessionHistory.store_path(@sid)) == "{\"d\":4}\n"
    end

    test "redacts workspace secret values before they reach the store", %{base: base} do
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "sh-#{System.unique_integer([:positive])}",
          worker_env: %{"API_TOKEN" => %{"value" => "tok_SUPERSECRET", "secret" => true}}
        })

      {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "t", workspace_id: ws.id})
      create_run(Path.join(base, "gone"), task.id)

      tmp = run_tmp_with_session(base, "{\"echo\":\"KEY=tok_SUPERSECRET\"}\n")
      assert [@sid] = SessionHistory.preserve(tmp)

      stored = File.read!(SessionHistory.store_path(@sid))
      refute stored =~ "tok_SUPERSECRET"
      assert stored =~ "KEY="
    end

    test "RunTmp.sweep/1 preserves a stale run tmp's session before deleting it", %{base: base} do
      root = Path.join(base, "sweep-root")
      stale = run_tmp_with_session(root, "{\"e\":5}\n")
      File.touch!(stale, {{2020, 1, 1}, {0, 0, 0}})

      assert [^stale] = Arbiter.Worker.RunTmp.sweep(root: root, max_age_ms: 1000)
      refute File.exists?(stale)
      assert File.read!(SessionHistory.store_path(@sid)) == "{\"e\":5}\n"
    end

    test "seed/3 falls back to the store when the live file vanishes after lookup", %{
      base: base,
      new_config: new
    } do
      prior = Path.join(base, "prior-config")
      File.mkdir_p!(Path.dirname(jsonl_path(prior, "-old")))
      File.write!(jsonl_path(prior, "-old"), "{\"f\":6}\n")
      create_run(prior)

      # What the reaper does: preserve, then delete the live file.
      tmp = Path.dirname(prior)
      File.mkdir_p!(Path.join(tmp, "claude-config/projects/-old"))

      File.cp!(
        jsonl_path(prior, "-old"),
        Path.join(tmp, "claude-config/projects/-old/#{@sid}.jsonl")
      )

      assert [@sid] = SessionHistory.preserve(tmp)

      assert {:ok, {:file, live}} = SessionHistory.find(@sid)
      File.rm!(live)

      assert :ok = SessionHistory.seed(new, @cwd, @sid)
      dest = jsonl_path(new, Arbiter.Usage.ClaudeSessionFile.project_slug(@cwd))
      assert File.read!(dest) == "{\"f\":6}\n"
    end

    test "seeding from the store discards it; prune/0 drops aged entries", %{
      base: base,
      new_config: new
    } do
      tmp = run_tmp_with_session(base, "{\"g\":7}\n")
      assert [@sid] = SessionHistory.preserve(tmp)
      File.rm_rf!(tmp)

      assert :ok = SessionHistory.seed(new, @cwd, @sid)
      refute File.exists?(SessionHistory.store_path(@sid))

      File.mkdir_p!(SessionHistory.store_dir())
      old = SessionHistory.store_path("old-sid")
      File.write!(old, "x")
      File.touch!(old, {{2020, 1, 1}, {0, 0, 0}})
      assert SessionHistory.prune() == 1
      refute File.exists?(old)
    end

    test "a dir with no session is a no-op", %{base: base} do
      assert [] = SessionHistory.preserve(Path.join(base, "nothing"))
    end
  end
end
