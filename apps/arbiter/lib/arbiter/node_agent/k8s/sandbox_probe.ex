defmodule Arbiter.NodeAgent.K8s.SandboxProbe do
  @moduledoc """
  The `runtime_class` readiness check's real pod (KH1, bd-27o4ls): a server-side dry run
  cannot see the kubelet, so a `RuntimeClass` whose handler refuses the pod (runsc and
  `hostUsers: false`: `RuntimeClass handler "runsc" does not support user namespaces`)
  passes it and every worker pod then hangs in `ContainerCreating`.

  `run/3` creates one short-lived pod under the configured class (the canary's shape
  with a command that exits at once, `Canary.sandbox_probe_pod/2`), waits until a
  container of it has started (the sandbox exists) and deletes it. While the pod is
  pending it reads the pod's `Event`s: a `FailedCreatePodSandBox` is the sandbox failure,
  and its message is what the readiness row reports.
  """

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.Client

  @default_timeout_ms 60_000
  @default_poll_ms 1_000
  @pull_failures ~w(ErrImagePull ImagePullBackOff InvalidImageName ErrImageNeverPull)

  @type result ::
          :started
          | {:sandbox_failed, String.t()}
          | {:not_started, :timeout | :image_pull | {:create_failed, term()} | {:bad_pod, term()}}

  @doc """
  Options: `:image` (as `Canary.pod/2`), `:sandbox_timeout_ms` (default 60 s) and
  `:poll_ms` (default 1 s). Never raises on an API failure; the pod is deleted whatever
  happens.
  """
  @spec run(Client.t(), map() | keyword(), keyword()) :: result()
  def run(client, config, opts) do
    case Canary.sandbox_probe_pod(config, opts) do
      {:ok, pod} -> create_and_wait(client, pod, opts)
      {:error, reason} -> {:not_started, {:bad_pod, reason}}
    end
  end

  defp create_and_wait(client, pod, opts) do
    name = pod["metadata"]["name"]

    case Client.create_pod(client, pod) do
      {:ok, _} ->
        try do
          timeout = Keyword.get(opts, :sandbox_timeout_ms, @default_timeout_ms)
          deadline = System.monotonic_time(:millisecond) + timeout
          poll(client, name, deadline, Keyword.get(opts, :poll_ms, @default_poll_ms))
        after
          Client.delete_pod(client, name, grace_period_seconds: 0)
        end

      {:error, reason} ->
        {:not_started, {:create_failed, reason}}
    end
  end

  defp poll(client, name, deadline, poll_ms) do
    case observe(client, name) do
      :started ->
        :started

      {:sandbox_failed, _} = failed ->
        failed

      :image_pull ->
        {:not_started, :image_pull}

      :pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:not_started, :timeout}
        else
          Process.sleep(poll_ms)
          poll(client, name, deadline, poll_ms)
        end
    end
  end

  defp observe(client, name) do
    case Client.get_pod(client, name) do
      {:ok, pod} -> pod |> status() |> judge(client, name)
      {:error, _} -> :pending
    end
  end

  defp status(pod), do: pod["status"] || %{}

  defp judge(status, client, name) do
    statuses = (status["initContainerStatuses"] || []) ++ (status["containerStatuses"] || [])

    cond do
      status["phase"] in ["Running", "Succeeded", "Failed"] -> :started
      Enum.any?(statuses, &ran?/1) -> :started
      Enum.any?(statuses, &pull_failed?/1) -> :image_pull
      true -> sandbox_event(client, name)
    end
  end

  defp ran?(cs), do: is_map(cs["state"]["running"]) or is_map(cs["state"]["terminated"])

  defp pull_failed?(cs), do: get_in(cs, ["state", "waiting", "reason"]) in @pull_failures

  defp sandbox_event(client, name) do
    with {:ok, events} <- Client.list_pod_events(client, name),
         %{"message" => message} <-
           Enum.find(events, &(&1["reason"] == "FailedCreatePodSandBox")) do
      {:sandbox_failed, message}
    else
      _ -> :pending
    end
  end
end
