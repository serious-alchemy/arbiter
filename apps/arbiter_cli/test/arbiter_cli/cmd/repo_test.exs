defmodule ArbiterCli.Cmd.RepoTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Repo

  @rigs %{
    "data" => [
      %{
        "name" => "arbiter",
        "source" => "default",
        "path" => "/dev/arbiter",
        "workers" => 1,
        "worktrees" => 2
      },
      %{
        "name" => "other",
        "source" => "(app)",
        "path" => "/dev/other",
        "workers" => 0,
        "worktrees" => 0
      }
    ]
  }

  test "list delegates to the repos endpoint" do
    stub_get("/api/repos", @rigs)
    {out, _err, code} = capture(fn -> Repo.run(["list", "--json"]) end)
    assert code == 0
    assert out =~ "arbiter"
  end

  test "list prints one row per repo in text mode" do
    stub_get("/api/repos", %{
      "data" => [
        %{"name" => "arbiter", "path" => "/home/ryan/dev/arbiter", "source" => "config"},
        %{"name" => "tonic", "path" => "/home/ryan/dev/tonic", "source" => "config"}
      ]
    })

    {out, _err, code} = capture(fn -> Repo.run(["list"]) end)
    assert code == 0
    assert out =~ "arbiter"
    assert out =~ "/home/ryan/dev/arbiter"
    assert out =~ "tonic"
  end

  test "list empty prints placeholder" do
    stub_get("/api/repos", %{"data" => []})
    {out, _err, code} = capture(fn -> Repo.run(["list"]) end)
    assert code == 0
    assert out =~ "(no repos registered)"
  end

  test "list --json emits {\"data\": [...]}" do
    stub_get("/api/repos", %{
      "data" => [%{"name" => "arbiter", "path" => "/home/ryan/dev/arbiter", "source" => "config"}]
    })

    {out, _err, code} = capture(fn -> Repo.run(["list", "--json"]) end)
    assert code == 0
    assert {:ok, %{"data" => [_]}} = Jason.decode(String.trim(out))
  end

  test "ls is an alias for list" do
    stub_get("/api/repos", %{"data" => []})
    {out, _err, code} = capture(fn -> Repo.run(["ls"]) end)
    assert code == 0
    assert out =~ "(no repos registered)"
  end

  test "show finds a repo by name" do
    stub_get("/api/repos/arbiter", hd(@rigs["data"]))
    {out, _err, code} = capture(fn -> Repo.run(["show", "arbiter", "--json"]) end)
    assert code == 0
    assert out =~ "arbiter"
    assert out =~ "/dev/arbiter"
  end

  test "show renders detail in text mode" do
    stub_get("/api/repos/arbiter", hd(@rigs["data"]))
    {out, _err, code} = capture(fn -> Repo.run(["show", "arbiter"]) end)
    assert code == 0
    assert out =~ "arbiter"
    assert out =~ "Worktrees: 2"
  end

  test "show errors when the repo is unknown" do
    stub_get(
      "/api/repos/ghost",
      %{"error" => %{"type" => "not_found", "message" => "repo \"ghost\" not found"}},
      404
    )

    {_out, err, code} = capture(fn -> Repo.run(["show", "ghost"]) end)
    assert code == 1
    assert err =~ "no repo named"
  end

  test "show --json errors with non-zero exit code when the repo is unknown" do
    stub_get(
      "/api/repos/ghost",
      %{"error" => %{"type" => "not_found", "message" => "repo \"ghost\" not found"}},
      404
    )

    {out, _err, code} = capture(fn -> Repo.run(["show", "ghost", "--json"]) end)
    assert code != 0
    assert out =~ "no repo named"
  end

  test "list returns both entries for same-name repo across workspaces in text and json" do
    two_workspaces_same_name = %{
      "data" => [
        %{
          "name" => "shared-repo",
          "source" => "ws-one",
          "path" => "/dev/ws-one/shared-repo",
          "workers" => 0,
          "worktrees" => 0
        },
        %{
          "name" => "shared-repo",
          "source" => "ws-two",
          "path" => "/dev/ws-two/shared-repo",
          "workers" => 0,
          "worktrees" => 0
        }
      ]
    }

    stub_get("/api/repos", two_workspaces_same_name)
    {out_text, _err, code_text} = capture(fn -> Repo.run(["list"]) end)
    assert code_text == 0
    assert out_text =~ "ws-one"
    assert out_text =~ "ws-two"

    stub_get("/api/repos", two_workspaces_same_name)
    {out_json, _err, code_json} = capture(fn -> Repo.run(["list", "--json"]) end)
    assert code_json == 0
    assert {:ok, %{"data" => entries}} = Jason.decode(String.trim(out_json))
    assert length(entries) == 2
  end

  test "show requires a name" do
    {_out, err, code} = capture(fn -> Repo.run(["show"]) end)
    assert code == 1
    assert err =~ "requires a repo name"
  end
end
