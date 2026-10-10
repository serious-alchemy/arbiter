defmodule Arbiter.NodeAgent.K8s.PodState do
  @moduledoc """
  The pure pod-state function of the Kubernetes in-cluster agent (K3,
  `docs/design/remote-workers.md` k8s §3.3): a Pod object (the JSON map the API
  returns, string keys) in, the run state the controller reports out. No I/O, no
  clock of its own (`:now` is an option), so every row of the table is a plain
  unit test (`test/arbiter/node_agent/k8s/pod_state_test.exs`).

  ## Result

    * `{:pending, %{reason: :unschedulable | :queued | :unscheduled, message: msg}}`
      — not scheduled. `:unschedulable` keeps the scheduler's message verbatim.
    * `{:starting, %{detail: :pulling | :seeding | :services}}`
    * `{:running, %{}}` — the `worker` container is running; the only state the
      primary treats a run as started in.
    * `{:terminating, %{}}` — `deletionTimestamp` is set, no outcome yet.
    * `{:exit, %{exit_code, oom?, reason}}` — `reason` is `:exited | :oom_killed |
      :deadline | :init_failed | :failed`.
    * `{:refuse, %{reason: :image_unavailable, detail: text}}` — the pod must be
      deleted.
    * `{:interrupted, %{cause: :pod_disrupted, reason: text}}` — eviction,
      preemption, node shutdown or someone else's delete; same policy as
      `node_lost`, no resume attempt consumed.

  ## Precedence

  When one pod matches several rows the first of these wins: a deadline; a
  worker that finished cleanly (exit 0); a disruption; a terminated worker; a
  failed init container or `phase: Failed`; `deletionTimestamp`; running; the
  scheduling rows; the starting rows. So an evicted pod is `interrupted` even
  though eviction killed the worker, and a cancelled pod whose worker already
  exited reports the exit rather than `terminating`.

  Rows beyond the §3.3 table (needed for the function to be total): a failed init
  container (`init_failed`), any other `phase: Failed` (`failed`), and the
  kubelet's node-shutdown reasons (`Shutdown`, `Terminated`, `NodeLost`), which
  are disruptions.
  """

  @worker "worker"
  @seed "seed"

  @pull_failures ~w(ImagePullBackOff ErrImagePull InvalidImageName CreateContainerConfigError)
  @disrupted_reasons ~w(Evicted Preempting Shutdown Terminated NodeLost)
  @default_pull_timeout_s 300

  @type state ::
          {:pending, map()}
          | {:starting, map()}
          | {:running, map()}
          | {:terminating, map()}
          | {:exit, map()}
          | {:refuse, map()}
          | {:interrupted, map()}

  @doc """
  The run state of `pod`.

  Options: `:now` (a `DateTime`, default now) and `:pull_timeout_s` (how long an
  image error may persist before the run is refused, default
  #{@default_pull_timeout_s}).
  """
  @spec observe(map(), keyword()) :: state()
  def observe(pod, opts \\ []) do
    status = pod["status"] || %{}
    worker = container_state(status["containerStatuses"], @worker)

    cond do
      status["phase"] == "Failed" and status["reason"] == "DeadlineExceeded" ->
        {:exit, exit_info(worker, :deadline)}

      match?({:terminated, %{"exitCode" => 0}}, worker) ->
        {:exit, exit_info(worker, :exited)}

      reason = disruption(status) ->
        {:interrupted, %{cause: :pod_disrupted, reason: reason}}

      match?({:terminated, _}, worker) ->
        {:exit, exit_info(worker, nil)}

      failed = failed_init(status) ->
        {:exit, init_failed(failed)}

      status["phase"] == "Failed" ->
        {:exit,
         %{
           reason: :failed,
           detail: status["reason"],
           message: status["message"],
           exit_code: nil,
           oom?: false
         }}

      get_in(pod, ["metadata", "deletionTimestamp"]) != nil ->
        {:terminating, %{}}

      match?({:running, _}, worker) ->
        {:running, %{}}

      true ->
        pre_start(pod, status, opts)
    end
  end

  @doc """
  The run state for a Pod the API reported as DELETED (`pod` is its last known
  object). A worker that had already terminated keeps its exit; a delete the
  controller asked for (`expected?: true`) is `:gone`; anything else is someone
  else's delete, an interruption.
  """
  @spec deleted(map(), keyword()) :: state() | :gone
  def deleted(pod, opts \\ []) do
    expected? = Keyword.get(opts, :expected?, false)

    case observe(pod, opts) do
      {:exit, _} = exit -> exit
      {:interrupted, _} = interrupted -> interrupted
      _ when expected? -> :gone
      _ -> {:interrupted, %{cause: :pod_disrupted, reason: "deleted"}}
    end
  end

  @doc "The heartbeat vocabulary (`pending | starting | running | terminating`), or nil for an outcome."
  @spec run_state(state()) :: :pending | :starting | :running | :terminating | nil
  def run_state({tag, _}) when tag in [:pending, :starting, :running, :terminating], do: tag
  def run_state(_), do: nil

  # --- before the worker runs -------------------------------------------------

  defp pre_start(pod, status, opts) do
    case schedule_condition(status) do
      {:unscheduled, info} ->
        {:pending, info}

      :scheduled ->
        case image_failure(pod, status, opts) do
          nil -> {:starting, %{detail: start_detail(status)}}
          detail -> {:refuse, %{reason: :image_unavailable, detail: detail}}
        end
    end
  end

  defp schedule_condition(status) do
    case condition(status, "PodScheduled") do
      %{"status" => "True"} ->
        :scheduled

      %{"status" => "False", "reason" => "Unschedulable"} = c ->
        {:unscheduled, %{reason: :unschedulable, message: c["message"]}}

      %{"status" => "False", "reason" => "SchedulingGated"} = c ->
        {:unscheduled, %{reason: :queued, message: c["message"]}}

      %{"status" => "False"} = c ->
        {:unscheduled, %{reason: :unscheduled, detail: c["reason"], message: c["message"]}}

      nil ->
        # No condition: either brand new, or the kubelet already has it.
        if status["startTime"] || status["containerStatuses"] || status["initContainerStatuses"],
          do: :scheduled,
          else: {:unscheduled, %{reason: :unscheduled, message: nil}}
    end
  end

  # An image error counts only once it has persisted past `pull_timeout_s`: the
  # kubelet reports ErrImagePull/ImagePullBackOff for ordinary registry blips too.
  defp image_failure(pod, status, opts) do
    waiting =
      for list <- [status["initContainerStatuses"], status["containerStatuses"]],
          cs <- list || [],
          %{"reason" => reason} = w <- [get_in(cs, ["state", "waiting"]) || %{}],
          reason in @pull_failures do
        "#{cs["name"]}: #{reason}#{if w["message"], do: " - " <> w["message"], else: ""}"
      end

    with [detail | _] <- waiting,
         since when not is_nil(since) <- clock_start(pod, status),
         true <-
           DateTime.diff(Keyword.get(opts, :now) || DateTime.utc_now(), since) >
             pull_timeout(opts) do
      detail
    else
      _ -> nil
    end
  end

  defp pull_timeout(opts), do: Keyword.get(opts, :pull_timeout_s, @default_pull_timeout_s)

  defp clock_start(pod, status) do
    parse_time(status["startTime"]) || parse_time(get_in(pod, ["metadata", "creationTimestamp"]))
  end

  defp parse_time(nil), do: nil

  defp parse_time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  # pulling: nothing has started yet; seeding: the seed init container is the
  # one in flight; services: seed is done and the sidecars (test services, the
  # snapshotter) or the worker container are what remains.
  defp start_detail(status) do
    case container_state(status["initContainerStatuses"], @seed) do
      {:terminated, _} -> :services
      {:running, _} -> :seeding
      _ -> :pulling
    end
  end

  # --- outcomes ---------------------------------------------------------------

  defp exit_info(worker, reason) do
    {code, oom?} =
      case worker do
        {:terminated, t} -> {t["exitCode"], t["reason"] == "OOMKilled"}
        _ -> {nil, false}
      end

    %{exit_code: code, oom?: oom?, reason: reason || if(oom?, do: :oom_killed, else: :exited)}
  end

  defp init_failed(%{"name" => name, "state" => %{"terminated" => t}}) do
    %{
      reason: :init_failed,
      container: name,
      exit_code: t["exitCode"],
      oom?: t["reason"] == "OOMKilled"
    }
  end

  defp failed_init(status) do
    Enum.find(status["initContainerStatuses"] || [], fn cs ->
      case get_in(cs, ["state", "terminated", "exitCode"]) do
        code when is_integer(code) and code != 0 -> true
        _ -> false
      end
    end)
  end

  defp disruption(status) do
    case condition(status, "DisruptionTarget") do
      %{"status" => "True"} = c ->
        c["reason"] || "DisruptionTarget"

      _ ->
        if status["reason"] in @disrupted_reasons, do: status["reason"]
    end
  end

  # --- plumbing ---------------------------------------------------------------

  defp condition(status, type), do: Enum.find(status["conditions"] || [], &(&1["type"] == type))

  defp container_state(nil, _name), do: nil

  defp container_state(statuses, name) do
    case Enum.find(statuses, &(&1["name"] == name)) do
      %{"state" => %{"running" => r}} -> {:running, r}
      %{"state" => %{"terminated" => t}} -> {:terminated, t}
      %{"state" => %{"waiting" => w}} -> {:waiting, w}
      _ -> nil
    end
  end
end
