defmodule Arbiter.Worker.CredentialPathsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Claude.Security
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.CredentialPaths
  alias Arbiter.Worker.Jail.Hide

  setup do
    home = Path.join(System.tmp_dir!(), "cp#{System.unique_integer([:positive])}")
    for d <- CredentialPaths.dirs(), do: File.mkdir_p!(Path.join(home, d))
    for f <- CredentialPaths.files(), do: File.write!(Path.join(home, f), "x")
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home}
  end

  test "includes the kubeconfig directory" do
    assert ".kube" in CredentialPaths.dirs()
  end

  test "Jail.Hide hides exactly the shared credential list", %{home: home} do
    hidden =
      Hide.paths(
        operator_home: home,
        data_dir: nil,
        database: nil,
        repos: [],
        own_repo: nil,
        unmask: []
      )

    # nested entries (`.config/gh`) must be hidden as their own path
    for d <- CredentialPaths.dirs() do
      assert Path.join(home, d) in hidden.dirs, "#{d} not hidden by Jail.Hide"
    end

    for f <- CredentialPaths.files() do
      assert Path.join(home, f) in hidden.files, "#{f} not hidden by Jail.Hide"
    end
  end

  test "the permission-layer deny covers every shared credential dir and file" do
    rules = Security.deny_rules(SecurityPolicy.resolve(nil))

    for d <- CredentialPaths.dirs() do
      assert "Read(~/#{d}/**)" in rules, "no Read deny for #{d}"
    end

    for f <- CredentialPaths.files() do
      assert "Read(~/#{f})" in rules, "no Read deny for #{f}"
    end
  end

  test "bash read-tools naming ~/.kube are denied" do
    rules = Security.deny_rules(SecurityPolicy.resolve(nil))
    assert "Bash(cat *.kube/*)" in rules
    assert "Bash(kubectl *~/.kube*)" in rules
  end

  test "worker env points KUBECONFIG at /dev/null so bare kubectl cannot reach the operator's cluster" do
    assert {"KUBECONFIG", "/dev/null"} in Claude.spawn_env([])
  end
end
