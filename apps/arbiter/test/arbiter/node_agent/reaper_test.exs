defmodule Arbiter.NodeAgent.ReaperTest do
  @moduledoc """
  RW12 (§10.6): the node-side reaper. It removes only what carries this node's
  `arbiter.node` label and the asking install's `arbiter.install` label, only for
  runs outside the primary's live set (and the agent's own table), and gives run
  directories and shadow clones a long minimum age because they may hold the only
  copy of un-checkpointed work.
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.{Config, Reaper, Runs}

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)

    config = %Config{
      node_home: home,
      credential: "arbn_x.y",
      primary_url: "http://127.0.0.1:1",
      node_id: "n1"
    }

    %{config: config}
  end

  defp container(name, run, install, node) do
    %{
      "Names" => [name],
      "Labels" => %{"arbiter.run" => run, "arbiter.install" => install, "arbiter.node" => node}
    }
  end

  # A podman that answers `ps` / `pod ps` from `ps` / `pods` and records the rest.
  defp runner(ps, pods \\ []) do
    test = self()

    fn _cmd, args, _opts ->
      send(test, {:podman, args})

      case args do
        ["ps" | _] -> {Jason.encode!(ps), 0}
        ["pod", "ps" | _] -> {Jason.encode!(pods), 0}
        _ -> {"", 0}
      end
    end
  end

  defp podman_calls(acc \\ []) do
    receive do
      {:podman, args} -> podman_calls([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp old_run_dir(config, run, age_s) do
    dir = Path.join([config.node_home, "runs", run])
    File.mkdir_p!(Path.join(dir, "worktree"))
    File.write!(Path.join(dir, "worktree/a"), "x")
    mtime = System.os_time(:second) - age_s
    :ok = File.touch(dir, mtime)
    dir
  end

  test "removes this install's containers of runs outside the live set, and only those",
       %{config: config} do
    ps = [
      container("arb-live", "live-run", "inst1", "n1"),
      container("arb-dead", "dead-run", "inst1", "n1")
    ]

    result =
      Reaper.reap(config, %{install: "inst1", live_set: ["live-run"]},
        runner: runner(ps),
        podman: "podman"
      )

    assert result.containers == ["arb-dead"]
    calls = podman_calls()
    assert ["rm", "--force", "--ignore", "--time", "0", "arb-dead"] in calls
    refute ["rm", "--force", "--ignore", "--time", "0", "arb-live"] in calls

    # the listing itself is install- and node-scoped: another install's containers never come back
    [list] = Enum.filter(calls, &match?(["ps" | _], &1))
    assert "label=arbiter.install=inst1" in list
    assert "label=arbiter.node=n1" in list
  end

  test "a listed container whose labels name another install or node is never touched",
       %{config: config} do
    # defence in depth: even if the filter were ignored by podman, the labels are re-checked
    ps = [
      container("arb-other-install", "r1", "inst2", "n1"),
      container("arb-other-node", "r2", "inst1", "n2"),
      %{"Names" => ["arb-unlabelled"], "Labels" => nil},
      container("not-ours", "r3", "inst1", "n1")
    ]

    result =
      Reaper.reap(config, %{install: "inst1", live_set: []}, runner: runner(ps), podman: "podman")

    assert result.containers == []
    refute Enum.any?(podman_calls(), &match?(["rm" | _], &1))
  end

  test "no install id, no reaping", %{config: config} do
    assert {:error, :no_install} = Reaper.reap(config, %{install: nil, live_set: []}, [])
    assert {:error, :no_install} = Reaper.reap(config, %{install: "", live_set: []}, [])
    assert podman_calls() == []
  end

  test "run directories: old and not live go; young or live stay", %{config: config} do
    old = old_run_dir(config, "old-dead", 3 * 86_400)
    young = old_run_dir(config, "young-dead", 60)
    live = old_run_dir(config, "old-live", 3 * 86_400)

    result =
      Reaper.reap(config, %{install: "inst1", live_set: ["old-live"]},
        runner: runner([]),
        podman: "podman"
      )

    assert result.dirs == ["old-dead"]
    refute File.exists?(old)
    assert File.dir?(young)
    assert File.dir?(live)
  end

  test "the minimum age is configurable", %{config: config} do
    dir = old_run_dir(config, "dead", 120)

    Reaper.reap(config, %{install: "inst1", live_set: []},
      runner: runner([]),
      podman: "podman",
      min_age_s: 60
    )

    refute File.exists?(dir)
  end

  test "test-services pods are judged by the live set, labelled to this install and node",
       %{config: config} do
    pods = [
      %{
        "Name" => "arb-a-pod",
        "Labels" => %{"arbiter.test-services" => "1", "arbiter.run" => "dead-run"}
      },
      %{
        "Name" => "arb-b-pod",
        "Labels" => %{"arbiter.test-services" => "1", "arbiter.run" => "live-run"}
      }
    ]

    result =
      Reaper.reap(config, %{install: "inst1", live_set: ["live-run"]},
        runner: runner([], pods),
        podman: "podman"
      )

    assert result.pods == ["arb-a-pod"]
    [pod_ps] = Enum.filter(podman_calls(), &match?(["pod", "ps" | _], &1))
    assert "label=arbiter.install=inst1" in pod_ps
    assert "label=arbiter.node=n1" in pod_ps
  end
end
