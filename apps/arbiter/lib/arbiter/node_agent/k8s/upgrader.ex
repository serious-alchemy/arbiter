defmodule Arbiter.NodeAgent.K8s.Upgrader do
  @moduledoc """
  A cluster node's self-upgrade (`docs/design/remote-workers.md` K§2.4 step 3, ticket
  K14). The controller's image is immutable, so the machine's tarball upgrade
  (`Arbiter.NodeAgent.Upgrader`) does not apply: a `hello_ok` (or `upgrade` push) for a
  cluster node carries `upgrade{version, image}`, and this process moves the controller to
  that image with `Arbiter.NodeAgent.K8s.SelfUpgrade`, which patches the controller
  container of its own Deployment and nothing else. The `Recreate` strategy then replaces
  this pod; worker pods survive it and the next controller adopts them (K§3.5).

  It answers the same `request/2` call as the machine's upgrader, so
  `Arbiter.NodeAgent.Connection` hands it the spec without knowing which node it is.

    * **When idle** (`when_idle`, the conservative default of K§2.4): while a run is live
      (`pending`, `starting`, `running`, `terminating`) it waits, and tries again every
      `:retry_ms`. The primary's skew rules keep new work off an `outdated` node meanwhile.
    * **Not allowed** (`ARB_K8S_SELF_UPGRADE` is not `true`, the Role cannot patch): the
      status says `disabled`, and the primary shows the operator the `kubectl set image`
      command for the node instead.
    * The same spec again (every `hello_ok` repeats it) is not a second attempt; a failed
      `PATCH` (an API error) is retried. The status file's `upgrade` block says where it is:
      `waiting_for_idle | patched | rolling | disabled | refused | failed`.

  Options: `:client`, `:version` (the running one; required), `:status` (the
  `Arbiter.NodeAgent.Status` server), `:enabled?` (default
  `SelfUpgrade.available?/0`), `:idle_fun` (default: no live run in
  `Arbiter.NodeAgent.Backend.K8s.inventory/0`), `:retry_ms` (default 15 000), `:name`.
  """

  use GenServer

  alias Arbiter.NodeAgent.Backend.K8s, as: Backend
  alias Arbiter.NodeAgent.K8s.SelfUpgrade
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrade

  require Logger

  @default_retry_ms 15_000
  @live ~w(pending starting running terminating)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc ~S[Ask for an upgrade to `spec` (`%{"version", "image"}`): `:started | :ignored`.]
  @spec request(GenServer.server(), map()) :: :started | :ignored
  def request(server \\ __MODULE__, spec), do: GenServer.call(server, {:request, spec})

  @doc "No run is live: what `when_idle` waits for."
  @spec idle?() :: boolean()
  def idle?, do: not Enum.any?(Backend.inventory(), &(&1["state"] in @live))

  @impl true
  def init(opts) do
    {:ok,
     %{
       client: Keyword.fetch!(opts, :client),
       version: Keyword.fetch!(opts, :version),
       status: Keyword.get(opts, :status, Status),
       enabled?: Keyword.get_lazy(opts, :enabled?, &SelfUpgrade.available?/0),
       idle_fun: Keyword.get(opts, :idle_fun, &idle?/0),
       retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
       pending: nil,
       timer: nil
     }}
  end

  @impl true
  def handle_call({:request, %{"version" => version, "image" => image} = spec}, _from, state)
      when is_binary(version) and is_binary(image) do
    cond do
      Upgrade.same_version?(version, state.version) -> {:reply, :ignored, state}
      state.pending == spec -> {:reply, :ignored, state}
      true -> {:reply, :started, attempt(%{state | pending: spec})}
    end
  end

  # A tarball spec (`sha256`, no `image`) is a machine's; nothing here can apply it.
  def handle_call({:request, _spec}, _from, state), do: {:reply, :ignored, state}

  @impl true
  def handle_info(:retry, %{pending: spec} = state) when is_map(spec),
    do: {:noreply, attempt(%{state | timer: nil})}

  def handle_info(_other, state), do: {:noreply, state}

  defp attempt(%{pending: spec} = state) do
    cancel(state.timer)
    result = SelfUpgrade.run(state.client, spec, enabled?: state.enabled?, idle?: idle(state))
    outcome(state, spec, result)
  end

  defp idle(state) do
    state.idle_fun.()
  catch
    # The run table could not be read: not knowing is not idle.
    :exit, _ -> false
  end

  defp outcome(state, spec, {:ok, :patched}) do
    Logger.info("k8s controller: Deployment patched to #{spec["image"]}; Recreate restarts it")
    put_status(state, spec, "patched")
    state
  end

  defp outcome(state, spec, {:ok, :current}) do
    put_status(state, spec, "rolling")
    state
  end

  defp outcome(state, spec, {:error, :busy}) do
    put_status(state, spec, "waiting_for_idle")
    retry(state)
  end

  defp outcome(state, spec, {:error, :disabled}) do
    Logger.info(
      "k8s controller: upgrade to #{spec["version"]} needs the operator " <>
        "(ARB_K8S_SELF_UPGRADE is not true)"
    )

    put_status(state, spec, "disabled")
    state
  end

  defp outcome(state, spec, {:error, :bad_image}) do
    Logger.warning("k8s controller: refusing upgrade image #{inspect(spec["image"])}")
    put_status(state, spec, "refused", "not an image of the repository this controller runs")
    state
  end

  defp outcome(state, spec, {:error, reason}) do
    Logger.warning("k8s controller: upgrade to #{spec["image"]} failed: #{inspect(reason)}")
    put_status(state, spec, "failed", inspect(reason, limit: 5, printable_limit: 300))
    retry(state)
  end

  defp retry(state), do: %{state | timer: Process.send_after(self(), :retry, state.retry_ms)}

  defp put_status(state, spec, word, error \\ nil) do
    upgrade =
      %{"state" => word, "version" => spec["version"], "image" => spec["image"]}
      |> then(&if(error, do: Map.put(&1, "error", error), else: &1))

    Status.put(state.status, %{upgrade: upgrade})
  catch
    # No status process (a test without one): nothing to record.
    :exit, _ -> :ok
  end

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
