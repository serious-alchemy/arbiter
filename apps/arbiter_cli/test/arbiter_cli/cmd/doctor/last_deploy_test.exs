defmodule ArbiterCli.Cmd.Doctor.LastDeployTest do
  # async: false — ARB_DATA_HOME is process-global.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Doctor.Checks
  alias ArbiterCli.Cmd.ReleaseDeploy.Status

  setup do
    home = Path.join(System.tmp_dir!(), "arb-ld-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    System.put_env("ARB_DATA_HOME", home)
    Process.delete(:bd2_deploy_status_path)

    on_exit(fn ->
      System.delete_env("ARB_DATA_HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "no deploy recorded is n/a" do
    assert %{name: "last deploy", status: :na, detail: detail} = Checks.check_last_deploy()
    assert detail =~ "no `arb server deploy` recorded"
  end

  test "reports the tag, time, outcome and backup path of a successful deploy" do
    Status.start("v2.0.0", %{})
    Status.finish("succeeded", %{backup_path: "/h/snapshots/arbiter-pre-v2.0.0-x.sqlite3"})

    assert %{status: :ok, detail: detail, blocks_readiness: false} =
             Checks.check_last_deploy()

    assert detail =~ "v2.0.0"
    assert detail =~ "succeeded"
    assert detail =~ "/h/snapshots/arbiter-pre-v2.0.0-x.sqlite3"
    assert detail =~ ~r/\d{4}-\d{2}-\d{2}T/
  end

  test "a rolled-back deploy is a warning: it never blocks readiness or fails doctor" do
    Status.start("v2.0.0", %{})

    Status.finish("rolled_back", %{
      rolled_back_to: "v1.9.0",
      restored_database: true,
      backup_path: "/h/b.sqlite3"
    })

    assert %{status: :warn, detail: detail, hint: hint, blocks_readiness: false} =
             Checks.check_last_deploy()

    assert detail =~ "rolled back to v1.9.0"
    assert detail =~ "database restored"
    assert hint =~ "deploy-status.json"
  end

  test "a deploy still running is ok; a dead one reads as interrupted" do
    Status.start("v2.0.0", %{})
    assert %{status: :ok, detail: running} = Checks.check_last_deploy()
    assert running =~ "in progress"

    File.write!(
      Status.path(),
      Jason.encode!(%{"state" => "running", "tag" => "v2.0.0", "pid" => "999999999"})
    )

    assert %{status: :warn, detail: dead} = Checks.check_last_deploy()
    assert dead =~ "interrupted"
  end

  test "is part of the doctor run" do
    stub_routes([{{"get", "/api/workspaces"}, {%{"data" => []}, 200}}])
    assert "last deploy" in Enum.map(Checks.run(), & &1.name)
  end
end
