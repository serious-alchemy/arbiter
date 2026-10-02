defmodule Arbiter.Worker.RunTmpTest do
  use ExUnit.Case, async: false

  alias Arbiter.Worker.RunTmp

  setup do
    root = Path.join(System.tmp_dir!(), "run-tmp-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:arbiter, :worker_tmp_root)
    Application.put_env(:arbiter, :worker_tmp_root, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbiter, :worker_tmp_root, previous),
        else: Application.delete_env(:arbiter, :worker_tmp_root)

      RunTmp.force_rm_rf(root)
    end)

    {:ok, root: root}
  end

  defp read_only_tree(dir) do
    File.mkdir_p!(Path.join(dir, "ro/inner"))
    File.write!(Path.join(dir, "ro/inner/f.txt"), "x")
    File.chmod!(Path.join(dir, "ro/inner/f.txt"), 0o400)
    File.chmod!(Path.join(dir, "ro/inner"), 0o500)
    File.chmod!(Path.join(dir, "ro"), 0o500)
  end

  test "create/1 makes a dir under the worker tmp root and env_pairs point at it", %{root: root} do
    assert {:ok, dir} = RunTmp.create("bd-abc123")
    assert File.dir?(dir)
    assert String.starts_with?(dir, root <> "/bd-abc123-")
    assert {"TMPDIR", ^dir} = List.keyfind(RunTmp.env_pairs(dir), "TMPDIR", 0)
    assert RunTmp.env_pairs(nil) == []
  end

  test "remove/1 deletes a tree containing read-only dirs and files" do
    {:ok, dir} = RunTmp.create("bd-ro")
    read_only_tree(dir)
    assert :ok = RunTmp.remove(dir)
    refute File.exists?(dir)
  end

  test "remove/1 refuses a path outside the worker tmp root" do
    outside =
      Path.join(System.tmp_dir!(), "run-tmp-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)
    assert :ok = RunTmp.remove(outside)
    assert File.dir?(outside)
  end

  test "sweep/1 removes only dirs older than the threshold", %{root: root} do
    {:ok, old} = RunTmp.create("old")
    {:ok, fresh} = RunTmp.create("fresh")
    read_only_tree(old)
    File.touch!(old, System.os_time(:second) - 3 * 24 * 3600)

    assert RunTmp.sweep(max_age_ms: 24 * 3600_000, root: root) == [old]
    refute File.exists?(old)
    assert File.dir?(fresh)
  end

  test "Sweeper removes orphans at boot", %{root: root} do
    {:ok, old} = RunTmp.create("orphan")
    File.touch!(old, System.os_time(:second) - 3 * 24 * 3600)
    pid = start_supervised!({Arbiter.Worker.RunTmp.Sweeper, [enabled: true, root: root]})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    refute File.exists?(old)
  end

  describe "diagnosis/1" do
    @mountinfo """
    22 1 8:1 / / rw - ext4 /dev/sda1 rw
    30 22 0:25 / /tmp rw - tmpfs tmpfs rw
    31 22 0:26 / /home/u rw - btrfs /dev/sdb rw
    """

    test "flags a root under a tmpfs mount" do
      d = RunTmp.diagnosis(root: "/tmp/w/run", mountinfo: @mountinfo)
      assert d.tmpfs and d.fstype == "tmpfs"
    end

    test "a disk-backed root is not flagged; size over threshold is", %{root: root} do
      File.write!(Path.join(root, "big"), String.duplicate("x", 100))
      d = RunTmp.diagnosis(root: root, mountinfo: @mountinfo <> "", warn_bytes: 10)
      assert d.size_bytes == 100 and d.over_threshold

      d = RunTmp.diagnosis(root: "/home/u/w", mountinfo: @mountinfo)
      refute d.tmpfs
      assert d.fstype == "btrfs"
      refute d.over_threshold
    end
  end
end
