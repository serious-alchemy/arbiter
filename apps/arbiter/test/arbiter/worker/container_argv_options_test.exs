defmodule Arbiter.Worker.ContainerArgvOptionsTest do
  @moduledoc """
  bd-ar7ql1 (RW8a): the additive `Container.argv/2` options (mount mapping,
  `--memory`/`--memory-swap`/`--cpus`, extra labels, optional no `--rm`) and
  the no-regression pin: without them the argv is byte-identical to before.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Container

  @image "localhost/arb-dev/beam:abc123"

  defp spec(overrides) do
    Map.merge(
      %{podman: "/usr/bin/podman", image: @image, name: "arb-run1", worktree: "/work/tree"},
      overrides
    )
  end

  defp argv(overrides \\ %{}), do: Container.argv(spec(overrides), ["claude", "--print"])
  defp flags(argv), do: Enum.take_while(argv, &(&1 != "--"))

  defp pairs(argv, flag),
    do:
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(&(hd(&1) == flag))
      |> Enum.map(&List.last/1)

  @hardening [
    "--read-only",
    "--cap-drop=all",
    "no-new-privileges"
  ]

  describe "no-regression pin (defaults are byte-identical)" do
    test "minimal spec" do
      assert argv() == [
               "/usr/bin/podman",
               "run",
               "--name",
               "arb-run1",
               "--init",
               "--log-driver=none",
               "--rm",
               "--pull=never",
               "--userns=keep-id",
               "--network=none",
               "--read-only",
               "--cap-drop=all",
               "--security-opt",
               "no-new-privileges",
               "--tmpfs",
               "/tmp:rw,nosuid,nodev",
               "--tmpfs",
               "/dev/shm:rw,nosuid,nodev,noexec,size=64m",
               "-v",
               "/work/tree:/work/tree:rw,Z",
               "-w",
               "/work/tree",
               "--",
               @image,
               "claude",
               "--print"
             ]
    end

    test "fully loaded spec with bridges" do
      full =
        argv(%{
          home: "/h",
          objects: "/o",
          git_dir: "/g",
          readonly_paths: ["/r"],
          cli_mounts: [{"/cli", "/opt/arbiter/cli/x"}],
          writable_paths: ["/w"],
          bridges: ["/b.sock"],
          tmpfs: ["/var/tmp"],
          env: [{"A", "1"}],
          inherit_env: ["TOK"],
          interactive: true
        })

      assert full == [
               "/usr/bin/podman",
               "run",
               "--name",
               "arb-run1",
               "--init",
               "--log-driver=none",
               "--rm",
               "--pull=never",
               "--userns=keep-id",
               "--network=none",
               "--read-only",
               "--cap-drop=all",
               "--security-opt",
               "no-new-privileges",
               "--security-opt",
               "label=disable",
               "--tmpfs",
               "/tmp:rw,nosuid,nodev",
               "--tmpfs",
               "/dev/shm:rw,nosuid,nodev,noexec,size=64m",
               "--tmpfs",
               "/var/tmp:rw,nosuid,nodev",
               "-v",
               "/work/tree:/work/tree:rw",
               "-v",
               "/g:/g:rw",
               "-v",
               "/h:/h:rw",
               "-v",
               "/o:/o:O",
               "-v",
               "/w:/w:rw",
               "-v",
               "/b.sock:/b.sock:ro",
               "-v",
               "/r:/r:ro",
               "-v",
               "/cli:/opt/arbiter/cli/x:ro",
               "-e",
               "TOK",
               "-e",
               "A=1",
               "-e",
               "HOME=/h",
               "-i",
               "-w",
               "/work/tree",
               "--",
               @image,
               "claude",
               "--print"
             ]
    end

    test "pod placement and readonly worktree" do
      a = argv(%{pod: "arb-pod", worktree_readonly: true})
      assert "--pod" in a and "--userns=keep-id" not in a
      assert "/work/tree:/work/tree:ro" in a
    end

    test "empty/nil new options change nothing" do
      assert argv(%{memory: nil, memory_swap: nil, cpus: nil, labels: [], mount_map: %{}}) ==
               argv()
    end
  end

  describe "resource limits" do
    test "memory, memory-swap and cpus" do
      f = flags(argv(%{memory: "4g", memory_swap: "4g", cpus: "2"}))
      assert pairs(f, "--memory") == ["4g"]
      assert pairs(f, "--memory-swap") == ["4g"]
      assert pairs(f, "--cpus") == ["2"]
    end

    test "each is independent" do
      f = flags(argv(%{memory: "512m"}))
      assert pairs(f, "--memory") == ["512m"]
      assert pairs(f, "--memory-swap") == []
      assert pairs(f, "--cpus") == []
    end
  end

  describe "labels" do
    test "extra labels become --label k=v" do
      f = flags(argv(%{labels: [{"arbiter.install", "i1"}, {"arbiter.node", "n1"}]}))
      assert pairs(f, "--label") == ["arbiter.install=i1", "arbiter.node=n1"]
    end
  end

  describe "keep (no --rm)" do
    test "keep: true omits --rm" do
      refute "--rm" in flags(argv(%{keep: true}))
    end

    test "keep: false keeps --rm" do
      assert "--rm" in flags(argv(%{keep: false}))
    end
  end

  describe "mount mapping" do
    test "maps the container side of mounts and the workdir" do
      a = argv(%{home: "/h", mount_map: %{"/work/tree" => "/mnt/wt", "/h" => "/mnt/h"}})
      assert pairs(a, "-v") |> Enum.member?("/work/tree:/mnt/wt:rw,Z")
      assert pairs(a, "-v") |> Enum.member?("/h:/mnt/h:rw,Z")
      assert pairs(a, "-w") == ["/mnt/wt"]
      assert "HOME=/mnt/h" in pairs(a, "-e")
    end

    test "cli mounts keep their destination; unmapped paths are identity" do
      a =
        argv(%{
          readonly_paths: ["/r"],
          cli_mounts: [{"/cli", "/opt/arbiter/cli/x"}],
          mount_map: %{"/work/tree" => "/mnt/wt", "/cli" => "/elsewhere"}
        })

      assert "/r:/r:ro" in pairs(a, "-v")
      assert "/cli:/opt/arbiter/cli/x:ro" in pairs(a, "-v")
    end
  end

  describe "hardening is independent of options" do
    test "always present" do
      opts = %{
        memory: "1g",
        memory_swap: "1g",
        cpus: "1",
        labels: [{"a", "b"}],
        keep: true,
        mount_map: %{"/work/tree" => "/x"}
      }

      for extra <- [%{}, %{bridges: ["/b.sock"]}, %{pod: "p"}] do
        f = flags(argv(Map.merge(opts, extra)))
        for h <- @hardening, do: assert(h in f)
        assert "label=disable" in f == (extra[:bridges] != nil)
      end
    end
  end
end
