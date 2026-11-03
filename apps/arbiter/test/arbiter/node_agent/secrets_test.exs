defmodule Arbiter.NodeAgent.SecretsTest do
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.{Cgroups, Secrets}

  setup do
    dir = Path.join(System.tmp_dir!(), "ns-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{rt: dir}
  end

  test "writes a 0600 file in a 0700 dir and nothing else", %{rt: rt} do
    assert {:ok, file} =
             Secrets.write("r1", %{"A" => "1", "B" => "two words"},
               runtime_dir: rt,
               require_tmpfs: false
             )

    assert file == Path.join([rt, "arbiter-node", "r1", "secrets.env"])
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700
    assert File.read!(file) == "export A='1'\nexport B='two words'\n"
  end

  test "values are single-quoted so nothing in one is interpreted by the shell", %{rt: rt} do
    value = "it's $(touch #{rt}/pwned) `x` \"y\" \\z"
    {:ok, file} = Secrets.write("r2", %{"T" => value}, runtime_dir: rt, require_tmpfs: false)
    {out, 0} = System.cmd("sh", ["-c", ". #{file}; printf %s \"$T\""])
    assert out == value
    refute File.exists?(Path.join(rt, "pwned"))
  end

  test "no secrets means no file", %{rt: rt} do
    assert {:ok, nil} = Secrets.write("r3", %{}, runtime_dir: rt, require_tmpfs: false)
    refute File.exists?(Path.join(rt, "arbiter-node"))
  end

  test "remove/2 deletes the file and its directory, and is idempotent", %{rt: rt} do
    {:ok, file} = Secrets.write("r4", %{"A" => "1"}, runtime_dir: rt, require_tmpfs: false)
    assert Secrets.runs(rt) == ["r4"]
    assert :ok = Secrets.remove(rt, "r4")
    refute File.exists?(file)
    assert :ok = Secrets.remove(rt, "r4")
    assert Secrets.runs(rt) == []
  end

  test "refuses to overwrite an existing secrets file", %{rt: rt} do
    {:ok, _} = Secrets.write("r5", %{"A" => "1"}, runtime_dir: rt, require_tmpfs: false)

    assert {:error, {:secrets_write_failed, :eexist}} =
             Secrets.write("r5", %{"A" => "2"}, runtime_dir: rt, require_tmpfs: false)
  end

  # SI4: a pull's registry credential is a containers auth file on the run's tmpfs.
  describe "the pull auth file (SI4)" do
    @body ~s({"auths":{"registry.example.com":{"auth":"dXNlcjpwdWxsLXB3"}}})

    defp mountinfo(rt, type) do
      path = Path.join(rt, "mountinfo-#{type}")
      File.write!(path, "36 35 98:0 / #{rt} rw,noatime - #{type} none rw\n")
      path
    end

    test "is a 0600 file in the run's 0700 directory, beside its secrets", %{rt: rt} do
      opts = [runtime_dir: rt, mountinfo: mountinfo(rt, "tmpfs")]

      assert {:ok, file} = Secrets.write_authfile("r7", @body, opts)
      assert file == Secrets.authfile(rt, "r7")
      assert Path.dirname(file) == Secrets.dir(rt, "r7")
      assert File.read!(file) == @body
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700

      # the run's secrets file still goes in beside it
      assert {:ok, _} = Secrets.write("r7", %{"A" => "1"}, opts)
    end

    test "is refused, and nothing written, when the runtime dir is not a tmpfs", %{rt: rt} do
      opts = [runtime_dir: rt, mountinfo: mountinfo(rt, "ext4")]

      assert {:error, {:secrets_not_on_tmpfs, ^rt, "ext4"}} =
               Secrets.write_authfile("r8", @body, opts)

      refute File.exists?(Secrets.dir(rt, "r8"))
      assert {:error, :no_runtime_dir} = Secrets.write_authfile("r8", @body, runtime_dir: "")
    end

    test "a stale file from an earlier open of the run is replaced, never written through",
         %{rt: rt} do
      opts = [runtime_dir: rt, require_tmpfs: false]
      {:ok, file} = Secrets.write_authfile("r9", "old", opts)

      assert {:ok, ^file} = Secrets.write_authfile("r9", @body, opts)
      assert File.read!(file) == @body

      # a link planted where the file goes is removed, not followed
      target = Path.join(rt, "elsewhere")
      File.write!(target, "untouched")
      File.rm!(file)
      File.ln_s!(target, file)

      assert {:ok, ^file} = Secrets.write_authfile("r9", @body, opts)
      assert File.read!(target) == "untouched"
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(file)
    end

    test "remove/2 takes it with the run's directory, alone or beside the secrets", %{rt: rt} do
      opts = [runtime_dir: rt, require_tmpfs: false]
      {:ok, file} = Secrets.write_authfile("r10", @body, opts)

      assert :ok = Secrets.remove(rt, "r10")
      refute File.exists?(file)
      refute File.exists?(Secrets.dir(rt, "r10"))

      {:ok, _} = Secrets.write_authfile("r11", @body, opts)
      {:ok, _} = Secrets.write("r11", %{"A" => "1"}, opts)
      assert :ok = Secrets.remove(rt, "r11")
      refute File.exists?(Secrets.dir(rt, "r11"))
    end
  end

  test "fails closed with no runtime dir, and when the dir is not a tmpfs", %{rt: rt} do
    prior = System.get_env("XDG_RUNTIME_DIR")
    System.delete_env("XDG_RUNTIME_DIR")
    on_exit(fn -> if prior, do: System.put_env("XDG_RUNTIME_DIR", prior) end)

    assert {:error, :no_runtime_dir} = Secrets.write("r6", %{"A" => "1"}, [])

    # The test tmp dir is on disk, not tmpfs: refused rather than written.
    case Secrets.write("r6", %{"A" => "1"}, runtime_dir: rt) do
      {:error, {:secrets_not_on_tmpfs, ^rt, _type}} -> :ok
      # a host whose tmp is itself a tmpfs: the write is allowed and is on tmpfs
      {:ok, file} -> assert File.exists?(file)
    end
  end

  describe "Cgroups" do
    setup %{rt: rt} do
      manager = Path.join([rt, "user.slice", "user-1000.slice", "user@1000.service"])
      File.mkdir_p!(manager)
      %{manager: manager, rt: rt}
    end

    test "delegated = listed and enabled in the user manager's cgroup", %{manager: m, rt: rt} do
      File.write!(Path.join(m, "cgroup.controllers"), "cpuset cpu io memory pids\n")
      File.write!(Path.join(m, "cgroup.subtree_control"), "cpu memory pids\n")
      assert Cgroups.delegated(cgroup_root: rt, uid: "1000") == ["cpu", "memory", "pids"]
    end

    test "nothing is delegated when the manager cgroup is missing", %{rt: rt} do
      assert Cgroups.delegated(cgroup_root: Path.join(rt, "none"), uid: "1000") == []
    end

    test "limit_opts: memory not delegated is refused, cpus is dropped" do
      assert {:error, :memory_not_delegated} = Cgroups.limit_opts(%{memory: "1g"}, ["pids"])

      assert {:ok, [memory: "1g"], [:cpus]} =
               Cgroups.limit_opts(%{memory: "1g", cpus: "2"}, ["memory"])

      assert {:ok, opts, []} = Cgroups.limit_opts(%{memory: "1g", cpus: "2"}, ["memory", "cpu"])
      assert Enum.sort(opts) == [cpus: "2", memory: "1g"]
      assert {:ok, [], []} = Cgroups.limit_opts(%{}, [])
    end
  end
end
