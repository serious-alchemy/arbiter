defmodule Arbiter.Nodes.AgentTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Agent

  @moduletag :tmp_dir

  # A data home laid out the way `arb server deploy` leaves it:
  # releases/<tag>/ unpacked, `current` -> releases/<tag>.
  defp install(home, tag, files) do
    dir = Path.join([home, "releases", tag])

    for {rel, content} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    File.ln_s!(dir, Path.join(home, "current"))
    dir
  end

  defp sha(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  describe "a retained published tarball" do
    test "is served as the pristine bytes, with the matching sha256", %{tmp_dir: home} do
      install(home, "v1.2.3", %{"bin/arbiter" => "x"})
      bytes = :crypto.strong_rand_bytes(2048)
      File.write!(Path.join(home, "releases/v1.2.3.tar.gz"), bytes)
      File.write!(Path.join(home, "releases/v1.2.3.tar.gz.sha256"), sha(bytes) <> "  a.tar.gz\n")

      assert {:ok, art} = Agent.artifact(home)
      assert art.version == "v1.2.3"
      assert art.sha256 == sha(bytes)
      assert art.size == 2048
      assert File.read!(art.path) == bytes
    end

    test "a sidecar that disagrees with the bytes is not trusted", %{tmp_dir: home} do
      install(home, "v1.2.3", %{"bin/arbiter" => "x"})
      File.write!(Path.join(home, "releases/v1.2.3.tar.gz"), "real bytes")
      File.write!(Path.join(home, "releases/v1.2.3.tar.gz.sha256"), String.duplicate("0", 64))

      assert {:ok, art} = Agent.artifact(home)
      assert art.sha256 == sha("real bytes")
    end
  end

  describe "a --local directory build (no tarball)" do
    @tree %{
      "bin/arbiter" => "#!/bin/sh\n",
      "erts-14.0/bin/beam.smp" => "beam",
      "lib/arbiter-1.0/ebin/arbiter.app" => "app",
      "releases/1.0/vm.args" => "args",
      "releases/1.0/COOKIE" => "SECRET-COOKIE",
      "releases/1.0/tmp/scratch" => "scratch",
      "releases/COOKIE" => "SECRET-COOKIE-2",
      ".env" => "SECRET=1",
      "notes.txt" => "stray"
    }

    defp names(path) do
      {:ok, entries} = :erl_tar.table(to_charlist(path), [:compressed])
      entries |> Enum.map(&to_string/1) |> Enum.sort()
    end

    test "packs an allowlisted tree: no cookie, tmp, dotfiles or strays", %{tmp_dir: home} do
      install(home, "local-20261006000000", @tree)

      assert {:ok, art} = Agent.artifact(home)
      assert art.version == "local-20261006000000"
      listed = names(art.path)

      assert "arbiter/bin/arbiter" in listed
      assert "arbiter/erts-14.0/bin/beam.smp" in listed
      assert "arbiter/lib/arbiter-1.0/ebin/arbiter.app" in listed
      assert "arbiter/releases/1.0/vm.args" in listed

      refute Enum.any?(listed, &String.contains?(&1, "COOKIE"))
      refute Enum.any?(listed, &String.contains?(&1, "/tmp"))
      refute Enum.any?(listed, &String.contains?(&1, ".env"))
      refute Enum.any?(listed, &String.contains?(&1, "notes.txt"))
      assert art.sha256 == sha(File.read!(art.path))
    end

    test "is cached: a second call serves the same bytes (stable sha)", %{tmp_dir: home} do
      install(home, "local-1", @tree)
      {:ok, first} = Agent.artifact(home)
      {:ok, second} = Agent.artifact(home)
      assert first.sha256 == second.sha256
      assert first.path == second.path
    end

    test "the cache does not live in the releases dir (prune must not see it)", %{tmp_dir: home} do
      install(home, "local-1", @tree)
      {:ok, art} = Agent.artifact(home)
      refute String.starts_with?(art.path, Path.join(home, "releases") <> "/")
    end
  end

  test "no current release is unavailable", %{tmp_dir: home} do
    assert {:error, :unavailable} = Agent.artifact(home)
  end

  test "a current release that is not an OTP release is unavailable", %{tmp_dir: home} do
    install(home, "v9", %{"README" => "no bin/arbiter"})
    assert {:error, :unavailable} = Agent.artifact(home)
  end

  test "find_by_sha only matches the served artifact", %{tmp_dir: home} do
    install(home, "local-1", %{"bin/arbiter" => "x"})
    {:ok, art} = Agent.artifact(home)
    assert {:ok, ^art} = Agent.find_by_sha(art.sha256, home)
    assert :error = Agent.find_by_sha(String.duplicate("a", 64), home)
    assert :error = Agent.find_by_sha("../../etc/passwd", home)
  end
end
