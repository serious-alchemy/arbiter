defmodule Arbiter.NodeAgent.Backend.K8s do
  @moduledoc """
  `Arbiter.NodeAgent.Backend` for a Kubernetes cluster (`docs/design/remote-workers.md`
  K§3.2, ticket K14): the in-cluster controller is the node, one bare Pod per run. A thin
  layer over the processes `Arbiter.NodeAgent.K8s.Boot` starts, addressed by their
  registered names: the run table `Arbiter.NodeAgent.K8s.Controller` and the pod
  channel's `Arbiter.NodeAgent.PodChannel.Runs`.

  What the protocol becomes for a cluster (K§3.2):

    * `hello` is `kind: "cluster"` with `caps{backend: k8s, image: registry, limits: pod,
      bridge_streams: mux, upgrade: image, self_upgrade, namespace}`, the controller's
      `capacity` (`ceiling` = the ConfigMap's `max_concurrent`) and `degraded` (the
      readiness canary's `netpol_unenforced`, the config loader's `bad_config`), its pods
      as `inventory.runs`, nothing retained, the readiness checks and `k8s_version`. No
      cpu/memory facts: the cluster's schedulable room is the scheduler's business (K§4.2).
    * `hb` carries the per-run state (`pending | starting | running | terminating`), the
      `capacity`, `degraded` and the readiness checks. With no controller to ask, it says
      only its `seq`, which leaves the primary's view as it was rather than clearing it.
    * `assign` is the controller's admission and pod; its refusal
      (`{:refuse, reason, detail}`) goes back as `run.refused` unchanged.
    * `cancel` deletes the pod at once; `quiesce` (the primary does not know the run) and
      the self-fence delete it with its grace period, so the snapshotter's SIGTERM upload
      can salvage a checkpoint (K§3.6).
    * `collect` asks the run's snapshotter for a checkpoint over the pod channel's
      `/commands`.

    * `stdout` is the controller's `pods/log` follower (K§3.4, K15): `ack` carries the
      primary's opaque cursor to it, `resume` the cursor `hello_ok` says the primary holds
      (before the `attach_all` that resends what it lacks).

  Not here yet (named so nobody assumes it): run adoption across a primary restart
  (`caps.run_hold`/`run_adopt` are not advertised: the primary answers such runs `unknown`
  and they are quiesced). `exec` (the pre-push recipe in a run's shape) is not offered.
  """
  @behaviour Arbiter.NodeAgent.Backend

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.PodChannel

  require Logger

  @controller Arbiter.NodeAgent.K8s.Controller
  @live ~w(pending starting running)

  # -- runs ------------------------------------------------------------------------

  @impl true
  def inventory, do: with_report([], & &1.runs)

  @impl true
  def start_run(%{spec: spec}) do
    Controller.assign(@controller, spec)
  catch
    :exit, reason ->
      {:error, {:refuse, :no_capacity, "the controller is not running: #{exit_reason(reason)}"}}
  end

  @impl true
  def signal(run, signal), do: call({:error, :not_found}, &Controller.signal(&1, run, signal))

  @impl true
  def stop({run, reason}), do: call({:error, :not_found}, &Controller.cancel(&1, run, reason))
  def stop(run), do: stop({run, "cancelled"})

  @impl true
  def outcome(run), do: call(nil, &Controller.outcome(&1, run))

  @impl true
  def collect(run, opts) do
    case Keyword.get(opts, :kind, "checkout") do
      "checkout" -> checkpoint(run)
      other -> {:error, {:unsupported_kind, other}}
    end
  end

  defp checkpoint(run) do
    case PodChannel.push_command(run, %{"op" => "checkpoint"}) do
      :ok -> :ok
      {:error, :unknown_run} -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @impl true
  def list_owned, do: call([], &Controller.run_ids/1)

  @impl true
  def reap(%{request: request}) do
    call({:error, :not_running}, fn controller ->
      Controller.reap(controller, %{install: request[:install], live_set: request[:live_set]})
    end)
  end

  @impl true
  def capacity, do: with_report(%{}, & &1.capacity)

  @impl true
  def readiness do
    with_report(not_ready("the controller is not running"), fn report ->
      report.readiness || not_ready("no readiness report yet")
    end)
  end

  # -- the connection's hooks --------------------------------------------------------

  @doc """
  The cluster `hello`. Its inventory is the controller's table, so it needs the
  controller: one that cannot report exits here and the connection retries, rather than
  telling the primary this node holds no runs.
  """
  @impl true
  def hello(%Config{} = config, readiness) do
    report = Controller.report(@controller)
    cluster = config.cluster || %{}

    %{
      "agent_version" => config.version,
      "proto" => Config.proto(),
      "kind" => "cluster",
      "arch" => to_string(:erlang.system_info(:system_architecture)),
      "caps" => %{
        "backend" => "k8s",
        "image" => "registry",
        "limits" => "pod",
        "bridge_streams" => "mux",
        "upgrade" => "image",
        "self_upgrade" => Map.get(cluster, :self_upgrade?, false) == true,
        "namespace" => Map.get(cluster, :namespace)
      },
      "capacity" => report.capacity,
      "degraded" => report.degraded,
      "inventory" => %{"runs" => report.runs, "retained" => []},
      "readiness" => report.readiness || readiness
    }
    |> put_present("k8s_version", Map.get(cluster, :k8s_version))
  end

  @impl true
  def heartbeat(%Config{}, seq) do
    with_report(%{"seq" => seq}, fn report ->
      %{
        "seq" => seq,
        "runs" => report.runs,
        "capacity" => report.capacity,
        "degraded" => report.degraded
      }
      |> put_present("readiness", report.readiness)
    end)
  end

  @impl true
  def attach(run), do: call({:error, :not_found}, &Controller.attach(&1, run))

  @impl true
  def attach_all(skip), do: call(:ok, &Controller.attach_all(&1, skip))

  # Pushes from the controller go to the connection by name; a disconnected connection
  # drops them, and `attach_all/1` says them again. Nothing to detach.
  @impl true
  def detach_all, do: :ok

  @impl true
  def fence_all do
    for %{"id" => run, "state" => state} <- inventory(), state in @live do
      cancel_with_grace(run, "fenced")
    end

    :ok
  end

  # The primary's cursor for the run's `pods/log` stream (K§3.4). A cast: acks are frequent.
  @impl true
  def ack(run, cursor) when is_binary(cursor) do
    Controller.ack(@controller, run, cursor)
  catch
    :exit, _ -> :ok
  end

  def ack(_run, _offset), do: :ok

  @impl true
  def resume(cursors), do: call(:ok, &Controller.resume(&1, cursors))

  @impl true
  def exit_ack(run), do: call(:ok, &Controller.exit_ack(&1, run))

  @impl true
  def quiesce(run), do: cancel_with_grace(run, "quiesced")

  @impl true
  def adopt(_run), do: {:error, :unsupported}

  # -- helpers -----------------------------------------------------------------------

  defp cancel_with_grace(run, reason),
    do: call({:error, :not_found}, &Controller.cancel(&1, run, reason, collect: true))

  defp with_report(default, fun) do
    fun.(Controller.report(@controller))
  catch
    :exit, _ -> default
  end

  defp call(default, fun) do
    fun.(@controller)
  catch
    :exit, reason ->
      Logger.warning("k8s backend: the controller did not answer: #{exit_reason(reason)}")
      default
  end

  defp exit_reason({reason, {GenServer, _fun, _args}}), do: inspect(reason, limit: 5)
  defp exit_reason(reason), do: inspect(reason, limit: 5)

  defp not_ready(detail) do
    %{
      "ready" => false,
      "checks" => [
        %{
          "id" => "controller",
          "name" => "controller",
          "status" => "fail",
          "detail" => detail,
          "hint" => nil
        }
      ]
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
