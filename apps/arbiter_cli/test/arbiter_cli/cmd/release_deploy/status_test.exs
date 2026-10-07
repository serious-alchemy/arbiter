defmodule ArbiterCli.Cmd.ReleaseDeploy.StatusTest do
  # async: false — mutates ARB_DATA_HOME and GITHUB_TOKEN.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.ReleaseDeploy.Status

  setup do
    home = Path.join(System.tmp_dir!(), "arb-st-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("ARB_DATA_HOME", home)
    System.delete_env("GITHUB_TOKEN")

    on_exit(fn ->
      System.delete_env("ARB_DATA_HOME")
      System.delete_env("GITHUB_TOKEN")
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  test "read/0 is nil before any deploy" do
    assert Status.read() == nil
  end

  test "start/2 records a running deploy with its tag, pid and start time", %{home: home} do
    Status.start("v2", %{source: "github", release_repo: "acme/arbiter"})

    assert %{"state" => "running", "tag" => "v2", "pid" => pid, "started_at" => started} =
             Status.read()

    assert pid == System.pid()
    assert {:ok, _, _} = DateTime.from_iso8601(started)
    assert File.exists?(Path.join(home, "deploy-status.json"))
  end

  test "phase/1 updates the phase without losing the rest" do
    Status.start("v2", %{})
    Status.phase("restarting")
    assert %{"state" => "running", "phase" => "restarting", "tag" => "v2"} = Status.read()
  end

  test "finish/2 records the outcome, backup path and finish time" do
    Status.start("v2", %{})

    Status.finish("rolled_back", %{
      backup_path: "/x/snap.sqlite3",
      restored_database: true,
      rolled_back_to: "v1",
      message: "did not come back green"
    })

    assert %{
             "state" => "rolled_back",
             "tag" => "v2",
             "backup_path" => "/x/snap.sqlite3",
             "restored_database" => true,
             "rolled_back_to" => "v1",
             "finished_at" => finished
           } = Status.read()

    assert {:ok, _, _} = DateTime.from_iso8601(finished)
  end

  test "finish/2 without a start still records (a hook firing before start)" do
    Status.finish("failed", %{message: "boom"})
    assert %{"state" => "failed", "message" => "boom"} = Status.read()
  end

  test "finishing twice keeps the first outcome" do
    Status.start("v2", %{})
    Status.finish("succeeded", %{})
    Status.finish("failed", %{message: "late halt hook"})
    assert %{"state" => "succeeded"} = Status.read()
  end

  test "a GITHUB_TOKEN value never reaches the file", %{home: home} do
    System.put_env("GITHUB_TOKEN", "ghp_supersecrettokenvalue123")
    Status.start("v2", %{})
    Status.finish("failed", %{message: "GET failed with Bearer ghp_supersecrettokenvalue123"})

    raw = File.read!(Path.join(home, "deploy-status.json"))
    refute raw =~ "ghp_supersecrettokenvalue123"
    assert raw =~ "[redacted]"
  end

  test "an unparseable file reads as nil rather than crashing", %{home: home} do
    File.write!(Path.join(home, "deploy-status.json"), "{not json")
    assert Status.read() == nil
  end

  describe "describe/1" do
    test "a succeeded deploy" do
      line =
        Status.describe(%{
          "state" => "succeeded",
          "tag" => "v2",
          "finished_at" => "2026-10-06T12:00:00Z",
          "backup_path" => "/x/snap.sqlite3"
        })

      assert line =~ "v2"
      assert line =~ "succeeded"
      assert line =~ "2026-10-06T12:00:00Z"
      assert line =~ "/x/snap.sqlite3"
    end

    test "a deploy with no backup says so" do
      assert Status.describe(%{"state" => "succeeded", "tag" => "v2"}) =~ "no database backup"
    end

    test "a rollback names the restore" do
      line =
        Status.describe(%{
          "state" => "rolled_back",
          "tag" => "v2",
          "rolled_back_to" => "v1",
          "restored_database" => true,
          "backup_path" => "/x/s.sqlite3"
        })

      assert line =~ "rolled back"
      assert line =~ "v1"
      assert line =~ "database restored"
    end

    test "a running deploy whose process is gone reads as interrupted" do
      stale = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_iso8601()

      assert Status.describe(%{
               "state" => "running",
               "tag" => "v2",
               "pid" => "999999999",
               "updated_at" => stale
             }) =~ "interrupted"
    end
  end
end
