defmodule ArbiterCli.Scripts.RelTemplatesTest do
  @moduledoc """
  bd-51m9ba: the release's `rel/env.sh.eex`, `rel/vm.args.eex` and
  `rel/remote.vm.args.eex` keep Erlang distribution on loopback and the
  cookie a per-install, owner-only secret.

  The templates are rendered exactly as `mix release` renders them (EEx with
  `@release`), and the rendered `env.sh` is sourced by `sh -e` the way
  `bin/arbiter` sources it, so these assertions are about the generated
  files, not the template text.
  """
  use ExUnit.Case, async: true

  import Bitwise

  @rel Path.expand("../../../../rel", __DIR__)
  @release %{name: :arbiter, version: "0.0.0-test"}

  @moduletag :tmp_dir

  defp render(name), do: EEx.eval_file(Path.join(@rel, name <> ".eex"), assigns: [release: @release])

  # A fake release root holding the rendered env.sh and a bundled COOKIE the
  # way the published tarball ships it (0644, same bytes for every install).
  defp release_root!(dir) do
    root = Path.join(dir, "rel")
    File.mkdir_p!(Path.join(root, "releases/0.0.0-test"))
    File.write!(Path.join(root, "releases/0.0.0-test/env.sh"), render("env.sh"))
    File.write!(Path.join(root, "releases/COOKIE"), "BUNDLEDPUBLICCOOKIE")
    File.chmod!(Path.join(root, "releases/COOKIE"), 0o644)
    root
  end

  # Source env.sh under `set -e` like bin/arbiter does, then print what the
  # script goes on to use. `env` replaces the inherited environment wholesale.
  defp source_env(root, env) do
    script = """
    set -e
    RELEASE_ROOT="$1"; RELEASE_NAME=arbiter; RELEASE_VSN=0.0.0-test
    . "$RELEASE_ROOT/releases/$RELEASE_VSN/env.sh"
    echo "ERL_EPMD_ADDRESS=$ERL_EPMD_ADDRESS"
    echo "RELEASE_DISTRIBUTION=$RELEASE_DISTRIBUTION"
    echo "RELEASE_NODE=$RELEASE_NODE"
    echo "RELEASE_COOKIE=$RELEASE_COOKIE"
    env | grep -E '^(ERL_EPMD_ADDRESS|RELEASE_DISTRIBUTION|RELEASE_NODE|RELEASE_COOKIE)=' | sed 's/^/exported:/'
    """

    base = %{"PATH" => System.get_env("PATH")}
    env = Map.merge(base, env)
    args = ["-i" | Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)] ++ ["sh", "-c", script, "sh", root]

    {out, status} = System.cmd("env", args, stderr_to_stdout: true)
    {parse(out), out, status}
  end

  defp parse(out) do
    for line <- String.split(out, "\n", trim: true),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {k, v}
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  describe "vm.args" do
    test "pins the node's distribution listener to 127.0.0.1" do
      assert render("vm.args") =~ ~r/^-kernel inet_dist_use_interface \{127,0,0,1\}$/m
    end

    test "the rpc/remote client's own listener is pinned to 127.0.0.1 too" do
      assert render("remote.vm.args") =~ ~r/^-kernel inet_dist_use_interface \{127,0,0,1\}$/m
    end
  end

  describe "env.sh" do
    test "binds epmd to loopback and names the node on 127.0.0.1, all exported", %{tmp_dir: dir} do
      {vars, out, 0} = source_env(release_root!(dir), %{"HOME" => Path.join(dir, "home")})

      assert vars["ERL_EPMD_ADDRESS"] == "127.0.0.1"
      assert vars["RELEASE_DISTRIBUTION"] == "name"
      assert vars["RELEASE_NODE"] == "arbiter@127.0.0.1"

      for var <- ~w(ERL_EPMD_ADDRESS RELEASE_DISTRIBUTION RELEASE_NODE RELEASE_COOKIE) do
        assert vars["exported:" <> var], "#{var} is not exported:\n#{out}"
      end
    end

    test "an inherited ERL_EPMD_ADDRESS cannot widen the epmd bind", %{tmp_dir: dir} do
      {vars, _out, 0} =
        source_env(release_root!(dir), %{
          "HOME" => Path.join(dir, "home"),
          "ERL_EPMD_ADDRESS" => "0.0.0.0"
        })

      assert vars["ERL_EPMD_ADDRESS"] == "127.0.0.1"
    end

    test "an operator-set RELEASE_NODE is kept", %{tmp_dir: dir} do
      {vars, _out, 0} =
        source_env(release_root!(dir), %{
          "HOME" => Path.join(dir, "home"),
          "RELEASE_NODE" => "other@127.0.0.1"
        })

      assert vars["RELEASE_NODE"] == "other@127.0.0.1"
    end

    test "creates a random per-install cookie at ~/.arbiter/release.cookie, mode 0600", %{
      tmp_dir: dir
    } do
      home = Path.join(dir, "home")
      {vars, _out, 0} = source_env(release_root!(dir), %{"HOME" => home})

      cookie_file = Path.join(home, ".arbiter/release.cookie")
      assert File.read!(cookie_file) == vars["RELEASE_COOKIE"]
      assert vars["RELEASE_COOKIE"] =~ ~r/\A[0-9a-f]{64}\z/
      assert mode(cookie_file) == 0o600
    end

    test "never uses the cookie bundled in the release tarball", %{tmp_dir: dir} do
      {vars, _out, 0} = source_env(release_root!(dir), %{"HOME" => Path.join(dir, "home")})

      refute vars["RELEASE_COOKIE"] == "BUNDLEDPUBLICCOOKIE"
    end

    test "tightens the bundled releases/COOKIE to 0600", %{tmp_dir: dir} do
      root = release_root!(dir)
      {_vars, _out, 0} = source_env(root, %{"HOME" => Path.join(dir, "home")})

      assert mode(Path.join(root, "releases/COOKIE")) == 0o600
    end

    test "reuses the cookie on every later invocation, so rpc matches the server", %{
      tmp_dir: dir
    } do
      root = release_root!(dir)
      home = Path.join(dir, "home")

      {first, _, 0} = source_env(root, %{"HOME" => home})
      {second, _, 0} = source_env(root, %{"HOME" => home})

      assert first["RELEASE_COOKIE"] == second["RELEASE_COOKIE"]
    end

    test "an existing cookie loosened to 0644 is kept but chmod'ed back to 0600", %{tmp_dir: dir} do
      home = Path.join(dir, "home")
      cookie_file = Path.join(home, ".arbiter/release.cookie")
      File.mkdir_p!(Path.dirname(cookie_file))
      File.write!(cookie_file, "operatorcookie")
      File.chmod!(cookie_file, 0o644)

      {vars, _out, 0} = source_env(release_root!(dir), %{"HOME" => home})

      assert vars["RELEASE_COOKIE"] == "operatorcookie"
      assert mode(cookie_file) == 0o600
    end

    test "ARB_DATA_HOME relocates the cookie with the rest of the deploy", %{tmp_dir: dir} do
      data = Path.join(dir, "data")

      {vars, _out, 0} =
        source_env(release_root!(dir), %{"HOME" => Path.join(dir, "home"), "ARB_DATA_HOME" => data})

      assert File.read!(Path.join(data, "release.cookie")) == vars["RELEASE_COOKIE"]
      refute File.exists?(Path.join(dir, "home/.arbiter/release.cookie"))
    end

    test "an explicit RELEASE_COOKIE wins and no cookie file is written", %{tmp_dir: dir} do
      home = Path.join(dir, "home")

      {vars, _out, 0} =
        source_env(release_root!(dir), %{"HOME" => home, "RELEASE_COOKIE" => "explicit"})

      assert vars["RELEASE_COOKIE"] == "explicit"
      refute File.exists?(Path.join(home, ".arbiter/release.cookie"))
    end

    test "an unwritable data home falls back to a throwaway cookie, never the bundled one", %{
      tmp_dir: dir
    } do
      data = Path.join(dir, "ro")
      File.mkdir_p!(data)
      File.chmod!(data, 0o500)
      on_exit(fn -> File.chmod(data, 0o700) end)

      {vars, out, 0} =
        source_env(release_root!(dir), %{"HOME" => Path.join(dir, "home"), "ARB_DATA_HOME" => data})

      assert vars["RELEASE_COOKIE"] =~ ~r/\A[0-9a-f]{64}\z/
      assert out =~ "throwaway"
      refute File.exists?(Path.join(data, "release.cookie"))
    end
  end
end
