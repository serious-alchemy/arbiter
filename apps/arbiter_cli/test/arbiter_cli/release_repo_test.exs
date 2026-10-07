defmodule ArbiterCli.ReleaseRepoTest do
  # async: false — mutates ARB_RELEASE_REPO.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.ReleaseRepo

  setup do
    System.delete_env("ARB_RELEASE_REPO")
    on_exit(fn -> System.delete_env("ARB_RELEASE_REPO") end)
    :ok
  end

  test "ARB_RELEASE_REPO wins over every other source" do
    System.put_env("ARB_RELEASE_REPO", "env/repo")
    Process.put(:bd2_build_release_repo, "build/repo")
    stub_routes([{{"get", "/api/version"}, {%{"release_repo" => "server/repo"}, 200}}])

    assert ReleaseRepo.resolve() == {:ok, "env/repo", :env}
  end

  test "an unset env falls back to the running server's own metadata" do
    Process.put(:bd2_build_release_repo, "build/repo")
    stub_routes([{{"get", "/api/version"}, {%{"release_repo" => "server/repo"}, 200}}])

    assert ReleaseRepo.resolve() == {:ok, "server/repo", :server}
  end

  test "an empty env is treated as unset" do
    System.put_env("ARB_RELEASE_REPO", "")
    stub_routes([{{"get", "/api/version"}, {%{"release_repo" => "server/repo"}, 200}}])

    assert ReleaseRepo.resolve() == {:ok, "server/repo", :server}
  end

  test "an unreachable server falls back to the CLI's build-time repo" do
    Process.put(:bd2_build_release_repo, "build/repo")
    stub_routes([{{"get", "/api/version"}, {%{"error" => "boom"}, 500}}])

    assert ReleaseRepo.resolve() == {:ok, "build/repo", :build}
  end

  test "a server that does not report a repo falls back to the build-time repo" do
    Process.put(:bd2_build_release_repo, "build/repo")
    stub_routes([{{"get", "/api/version"}, {%{"version" => "1.2.3", "release_repo" => nil}, 200}}])

    assert ReleaseRepo.resolve() == {:ok, "build/repo", :build}
  end

  test "no source at all is an error, never a silent default" do
    Process.put(:bd2_build_release_repo, false)
    stub_routes([{{"get", "/api/version"}, {%{"error" => "boom"}, 500}}])

    assert ReleaseRepo.resolve() == :error
  end

  test "a malformed slug from the server is ignored" do
    Process.put(:bd2_build_release_repo, "build/repo")
    stub_routes([{{"get", "/api/version"}, {%{"release_repo" => "not a slug; rm -rf"}, 200}}])

    assert ReleaseRepo.resolve() == {:ok, "build/repo", :build}
  end

  test "describe/1 names where the repo came from" do
    assert ReleaseRepo.describe(:env) =~ "ARB_RELEASE_REPO"
    assert ReleaseRepo.describe(:server) =~ "running server"
    assert ReleaseRepo.describe(:build) =~ "built"
  end
end
