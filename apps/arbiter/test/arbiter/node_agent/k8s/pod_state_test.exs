defmodule Arbiter.NodeAgent.K8s.PodStateTest do
  # The state table of `docs/design/remote-workers.md` (k8s §3.3), one test per
  # row. `PodState` is pure, so everything here is async and plain data.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.PodState

  @now ~U[2026-10-10 12:00:00Z]
  @timeout 120
  @opts [now: @now, pull_timeout_s: @timeout]

  defp pod(status, meta \\ %{}) do
    %{
      "metadata" =>
        Map.merge(%{"name" => "arb-run-1", "creationTimestamp" => "2026-10-10T11:00:00Z"}, meta),
      "status" => status
    }
  end

  defp scheduled(status) do
    pod(
      Map.merge(
        %{
          "phase" => "Pending",
          "startTime" => "2026-10-10T11:59:00Z",
          "conditions" => [%{"type" => "PodScheduled", "status" => "True"}]
        },
        status
      )
    )
  end

  defp waiting(name, reason, message \\ nil),
    do: %{"name" => name, "state" => %{"waiting" => %{"reason" => reason, "message" => message}}}

  defp running(name),
    do: %{"name" => name, "state" => %{"running" => %{"startedAt" => "2026-10-10T11:59:30Z"}}}

  defp terminated(name, code, reason \\ "Error"),
    do: %{"name" => name, "state" => %{"terminated" => %{"exitCode" => code, "reason" => reason}}}

  describe "pending" do
    test "Pending + PodScheduled=False/Unschedulable -> pending (unschedulable), message verbatim" do
      msg = "0/3 nodes are available: 3 Insufficient memory."

      pod =
        pod(%{
          "phase" => "Pending",
          "conditions" => [
            %{
              "type" => "PodScheduled",
              "status" => "False",
              "reason" => "Unschedulable",
              "message" => msg
            }
          ]
        })

      assert {:pending, %{reason: :unschedulable, message: ^msg}} = PodState.observe(pod, @opts)
    end

    test "PodScheduled=False/SchedulingGated (Kueue) -> pending (queued)" do
      pod =
        pod(%{
          "phase" => "Pending",
          "conditions" => [
            %{"type" => "PodScheduled", "status" => "False", "reason" => "SchedulingGated"}
          ]
        })

      assert {:pending, %{reason: :queued}} = PodState.observe(pod, @opts)
    end

    test "a pod with no status yet is pending, not starting" do
      assert {:pending, %{reason: :unscheduled}} =
               PodState.observe(%{"metadata" => %{"name" => "x"}}, @opts)
    end

    test "PodScheduled=False for another reason is pending with that reason kept" do
      pod =
        pod(%{
          "phase" => "Pending",
          "conditions" => [
            %{
              "type" => "PodScheduled",
              "status" => "False",
              "reason" => "Weird",
              "message" => "m"
            }
          ]
        })

      assert {:pending, %{reason: :unscheduled, detail: "Weird", message: "m"}} =
               PodState.observe(pod, @opts)
    end
  end

  describe "starting" do
    test "scheduled, worker ContainerCreating, no init started -> starting (pulling)" do
      pod =
        scheduled(%{
          "initContainerStatuses" => [waiting("seed", "PodInitializing")],
          "containerStatuses" => [waiting("worker", "PodInitializing")]
        })

      assert {:starting, %{detail: :pulling}} = PodState.observe(pod, @opts)
    end

    test "Init:* with the seed init container running -> starting (seeding)" do
      pod =
        scheduled(%{
          "initContainerStatuses" => [running("seed")],
          "containerStatuses" => [waiting("worker", "PodInitializing")]
        })

      assert {:starting, %{detail: :seeding}} = PodState.observe(pod, @opts)
    end

    test "seed done, service sidecars still coming up -> starting (services)" do
      pod =
        scheduled(%{
          "initContainerStatuses" => [
            terminated("seed", 0, "Completed"),
            running("svc-postgres"),
            waiting("snapshotter", "PodInitializing")
          ],
          "containerStatuses" => [waiting("worker", "PodInitializing")]
        })

      assert {:starting, %{detail: :services}} = PodState.observe(pod, @opts)
    end

    test "ImagePullBackOff before pull_timeout_s is still starting (pulling)" do
      pod =
        scheduled(%{
          "startTime" => "2026-10-10T11:59:00Z",
          "containerStatuses" => [waiting("worker", "ImagePullBackOff", "Back-off pulling image")]
        })

      assert {:starting, %{detail: :pulling}} = PodState.observe(pod, @opts)
    end
  end

  describe "refuse image_unavailable" do
    for reason <- ~w(ImagePullBackOff ErrImagePull InvalidImageName CreateContainerConfigError) do
      test "worker waiting #{reason} for longer than pull_timeout_s -> refuse" do
        pod =
          scheduled(%{
            "startTime" => "2026-10-10T11:50:00Z",
            "containerStatuses" => [waiting("worker", unquote(reason), "boom")]
          })

        assert {:refuse, %{reason: :image_unavailable, detail: detail}} =
                 PodState.observe(pod, @opts)

        assert detail =~ unquote(reason)
        assert detail =~ "boom"
      end
    end

    test "an init container stuck pulling counts the same" do
      pod =
        scheduled(%{
          "startTime" => "2026-10-10T11:50:00Z",
          "initContainerStatuses" => [waiting("seed", "ErrImagePull", "not found")],
          "containerStatuses" => [waiting("worker", "PodInitializing")]
        })

      assert {:refuse, %{reason: :image_unavailable, detail: detail}} =
               PodState.observe(pod, @opts)

      assert detail =~ "seed"
    end

    test "the clock is startTime, falling back to creationTimestamp" do
      pod =
        pod(
          %{
            "phase" => "Pending",
            "conditions" => [%{"type" => "PodScheduled", "status" => "True"}],
            "containerStatuses" => [waiting("worker", "ErrImagePull")]
          },
          %{"creationTimestamp" => "2026-10-10T11:00:00Z"}
        )

      assert {:refuse, _} = PodState.observe(pod, @opts)
    end
  end

  describe "running and exit" do
    test "containerStatuses[worker].state.running -> running" do
      pod =
        scheduled(%{
          "phase" => "Running",
          "initContainerStatuses" => [terminated("seed", 0, "Completed"), running("snapshotter")],
          "containerStatuses" => [running("worker")]
        })

      assert {:running, %{}} = PodState.observe(pod, @opts)
    end

    test "worker terminated -> exit with the exit code, oom? false" do
      pod =
        scheduled(%{"phase" => "Failed", "containerStatuses" => [terminated("worker", 3)]})

      assert {:exit, %{exit_code: 3, oom?: false, reason: :exited}} = PodState.observe(pod, @opts)
    end

    test "worker terminated 0 -> exit 0" do
      pod =
        scheduled(%{
          "phase" => "Succeeded",
          "containerStatuses" => [terminated("worker", 0, "Completed")]
        })

      assert {:exit, %{exit_code: 0, oom?: false}} = PodState.observe(pod, @opts)
    end

    test "worker terminated reason OOMKilled -> exit with oom? true" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "containerStatuses" => [terminated("worker", 137, "OOMKilled")]
        })

      assert {:exit, %{exit_code: 137, oom?: true, reason: :oom_killed}} =
               PodState.observe(pod, @opts)
    end

    test "only the worker container decides: a terminated sidecar is not an exit" do
      pod =
        scheduled(%{
          "phase" => "Running",
          "containerStatuses" => [running("worker"), terminated("other", 1)]
        })

      assert {:running, _} = PodState.observe(pod, @opts)
    end
  end

  describe "interrupted (pod_disrupted)" do
    test "DisruptionTarget=True condition -> interrupted" do
      pod =
        scheduled(%{
          "phase" => "Running",
          "containerStatuses" => [running("worker")],
          "conditions" => [
            %{
              "type" => "DisruptionTarget",
              "status" => "True",
              "reason" => "PreemptionByScheduler"
            }
          ]
        })

      assert {:interrupted, %{cause: :pod_disrupted, reason: "PreemptionByScheduler"}} =
               PodState.observe(pod, @opts)
    end

    test "DisruptionTarget=False is not a disruption" do
      pod =
        scheduled(%{
          "phase" => "Running",
          "containerStatuses" => [running("worker")],
          "conditions" => [%{"type" => "DisruptionTarget", "status" => "False"}]
        })

      assert {:running, _} = PodState.observe(pod, @opts)
    end

    test "status.reason Evicted -> interrupted, even though the worker was then killed" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "reason" => "Evicted",
          "message" => "The node was low on resource: memory.",
          "containerStatuses" => [terminated("worker", 137)]
        })

      assert {:interrupted, %{cause: :pod_disrupted, reason: "Evicted"}} =
               PodState.observe(pod, @opts)
    end

    test "status.reason Preempting -> interrupted" do
      pod = pod(%{"phase" => "Failed", "reason" => "Preempting"})

      assert {:interrupted, %{cause: :pod_disrupted, reason: "Preempting"}} =
               PodState.observe(pod, @opts)
    end

    test "a worker that exited 0 before the disruption landed is still an exit" do
      pod =
        scheduled(%{
          "phase" => "Succeeded",
          "containerStatuses" => [terminated("worker", 0, "Completed")],
          "conditions" => [
            %{
              "type" => "DisruptionTarget",
              "status" => "True",
              "reason" => "EvictionByEvictionAPI"
            }
          ]
        })

      assert {:exit, %{exit_code: 0}} = PodState.observe(pod, @opts)
    end

    test "pod object deleted by someone else -> interrupted" do
      pod = scheduled(%{"phase" => "Running", "containerStatuses" => [running("worker")]})

      assert {:interrupted, %{cause: :pod_disrupted, reason: "deleted"}} =
               PodState.deleted(pod, @opts)
    end

    test "a deleted pod whose worker had already terminated keeps its exit" do
      pod = scheduled(%{"phase" => "Failed", "containerStatuses" => [terminated("worker", 2)]})
      assert {:exit, %{exit_code: 2}} = PodState.deleted(pod, @opts)
    end

    test "a deletion the controller asked for is :gone, not an interruption" do
      pod = scheduled(%{"phase" => "Running", "containerStatuses" => [running("worker")]})
      assert :gone = PodState.deleted(pod, Keyword.put(@opts, :expected?, true))
    end
  end

  describe "deadline" do
    test "phase Failed + status.reason DeadlineExceeded -> exit with reason deadline" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "reason" => "DeadlineExceeded",
          "message" => "Pod was active on the node longer than the specified deadline",
          "containerStatuses" => [terminated("worker", 137)]
        })

      assert {:exit, %{reason: :deadline, exit_code: 137, oom?: false}} =
               PodState.observe(pod, @opts)
    end

    test "a deadline without a worker status still reports deadline" do
      pod = pod(%{"phase" => "Failed", "reason" => "DeadlineExceeded"})
      assert {:exit, %{reason: :deadline, exit_code: nil}} = PodState.observe(pod, @opts)
    end
  end

  describe "terminating" do
    test "deletionTimestamp set while the worker is running -> terminating" do
      pod =
        scheduled(%{"phase" => "Running", "containerStatuses" => [running("worker")]})
        |> put_in(["metadata", "deletionTimestamp"], "2026-10-10T11:59:59Z")

      assert {:terminating, %{}} = PodState.observe(pod, @opts)
    end

    test "deletionTimestamp set while still pending -> terminating" do
      pod =
        pod(%{"phase" => "Pending"}, %{"deletionTimestamp" => "2026-10-10T11:59:59Z"})

      assert {:terminating, %{}} = PodState.observe(pod, @opts)
    end

    test "a terminated worker beats terminating: the exit is what the primary needs" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "containerStatuses" => [terminated("worker", 143, "Error")]
        })
        |> put_in(["metadata", "deletionTimestamp"], "2026-10-10T11:59:59Z")

      assert {:exit, %{exit_code: 143}} = PodState.observe(pod, @opts)
    end

    test "an eviction in flight (deletionTimestamp + DisruptionTarget) is interrupted" do
      pod =
        scheduled(%{
          "phase" => "Running",
          "containerStatuses" => [running("worker")],
          "conditions" => [
            %{
              "type" => "DisruptionTarget",
              "status" => "True",
              "reason" => "EvictionByEvictionAPI"
            }
          ]
        })
        |> put_in(["metadata", "deletionTimestamp"], "2026-10-10T11:59:59Z")

      assert {:interrupted, _} = PodState.observe(pod, @opts)
    end
  end

  describe "failures outside the table" do
    test "an init container that failed -> exit with reason init_failed and the container named" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "initContainerStatuses" => [terminated("seed", 7)],
          "containerStatuses" => [waiting("worker", "PodInitializing")]
        })

      assert {:exit, %{reason: :init_failed, container: "seed", exit_code: 7, oom?: false}} =
               PodState.observe(pod, @opts)
    end

    test "an OOM-killed init container still reports oom?" do
      pod =
        scheduled(%{
          "phase" => "Failed",
          "initContainerStatuses" => [terminated("seed", 137, "OOMKilled")]
        })

      assert {:exit, %{reason: :init_failed, oom?: true}} = PodState.observe(pod, @opts)
    end

    test "phase Failed for an unrecognised reason -> exit failed, reason kept" do
      pod = pod(%{"phase" => "Failed", "reason" => "UnexpectedAdmissionError", "message" => "x"})

      assert {:exit, %{reason: :failed, detail: "UnexpectedAdmissionError"}} =
               PodState.observe(pod, @opts)
    end
  end

  describe "run_state/1 (the heartbeat vocabulary)" do
    test "maps live states to pending | starting | running | terminating, others to nil" do
      assert PodState.run_state({:pending, %{}}) == :pending
      assert PodState.run_state({:starting, %{}}) == :starting
      assert PodState.run_state({:running, %{}}) == :running
      assert PodState.run_state({:terminating, %{}}) == :terminating
      assert PodState.run_state({:exit, %{}}) == nil
      assert PodState.run_state({:refuse, %{}}) == nil
      assert PodState.run_state({:interrupted, %{}}) == nil
    end
  end
end
