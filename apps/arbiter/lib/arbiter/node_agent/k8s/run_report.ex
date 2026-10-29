defmodule Arbiter.NodeAgent.K8s.RunReport do
  @moduledoc """
  The wire payloads the k8s controller sends for a run
  (`docs/design/remote-workers.md` K§3.2, K§3.3, shaped like the machine agent's
  `Arbiter.NodeAgent.Run` pushes so `Arbiter.Nodes.RunStreams` reads both): pure
  functions from the controller's per-run record and a `PodState` outcome to JSON-ready
  maps.

    * `ready/1` — `run.ready`, sent at the worker container `Running`, never before;
    * `refused/3` — `run.refused{run, reason, detail}` (the primary takes none without
      its `run`);
    * `exit/2` — `exit{status, oom, cancelled, reason, snapshot, …}`; a pod the
      cluster took away (eviction, preemption, node shutdown, someone's `kubectl
      delete`) carries `pod_disrupted: true` (A5) and no status;
    * `cancelled/1` — the exit of a run the controller itself deleted;
    * `inventory/1` — one run in `hello.inventory.runs` and `hb.runs`, with the state
      vocabulary `pending | starting | running | terminating`, keyed `id` as the
      primary reads it (and `run`, as the other payloads name it).
  """

  @type entry :: %{
          required(:run) => String.t(),
          required(:pod) => String.t(),
          optional(atom()) => term()
        }

  @spec ready(entry()) :: map()
  def ready(entry), do: %{"run" => entry.run, "container" => entry.pod}

  @spec refused(String.t(), atom() | String.t(), String.t() | nil) :: map()
  def refused(run, reason, detail),
    do: %{"run" => run, "reason" => to_string(reason), "detail" => detail}

  @doc "The `exit` for a `PodState` `{:exit, info}` or `{:interrupted, info}`."
  @spec exit(entry(), {:exit | :interrupted, map()}) :: map()
  def exit(entry, {:exit, info}) do
    base(entry)
    |> Map.merge(%{
      "status" => info.exit_code,
      "oom" => info.oom? == true,
      "reason" => entry.cancelled || reason(info),
      "snapshot" => info |> Map.get(:snapshot) |> word()
    })
    |> put_present("detail", Map.get(info, :message) || Map.get(info, :detail))
  end

  def exit(entry, {:interrupted, info}) do
    preempted? = info[:preempted?] == true

    base(entry)
    |> Map.merge(%{
      "status" => nil,
      "oom" => false,
      "reason" => if(preempted?, do: "preempted", else: "pod_disrupted"),
      "pod_disrupted" => true
    })
    |> put_present("preempted", if(preempted?, do: true))
    |> put_present("detail", info[:message] || info[:reason])
  end

  @doc "The exit of a run we deleted ourselves, when the pod's own outcome was never seen."
  @spec cancelled(entry()) :: map()
  def cancelled(entry) do
    Map.merge(base(entry), %{
      "status" => nil,
      "oom" => false,
      "cancelled" => true,
      "reason" => entry.cancelled
    })
  end

  @spec inventory(entry()) :: map()
  def inventory(entry) do
    %{"id" => entry.run, "run" => entry.run, "pod" => entry.pod, "state" => state_word(entry)}
    |> put_present("reason", entry |> Map.get(:detail, %{}) |> Map.get(:reason) |> word())
    |> put_present("message", entry |> Map.get(:detail, %{}) |> Map.get(:message))
  end

  # -- internals ----------------------------------------------------------------

  defp base(entry),
    do: %{
      "run" => entry.run,
      "container" => entry.pod,
      "cancelled" => entry.cancelled != nil
    }

  defp reason(%{reason: reason}) when not is_nil(reason), do: to_string(reason)
  defp reason(_), do: "exited"

  defp state_word(%{phase: :live, state: state}), do: Atom.to_string(state)
  defp state_word(%{phase: phase}), do: Atom.to_string(phase)

  defp word(nil), do: nil
  defp word(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp word(other), do: other

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
