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

  defp create_run(config_dir) do
    {:ok, run} =
      Ash.create(Run, %{
        task_id: "bd-hist#{System.unique_integer([:positive])}",
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
end
