defmodule Arbiter.Worker.Image.Refresher do
  @moduledoc """
  The weekly base refresh and prune (bd-9r5jdt, design §2.4).

  Checks hourly whether `Arbiter.Worker.Image.Pins.due?/1` (pins exist and the
  last refresh was over a week ago). When it is, it re-resolves every base-image
  pin (`Pins.refresh/1`: a moved digest changes the content-hash tag of every
  image built on it, so the next dispatch builds the refreshed image lazily) and
  then prunes stale tags (`Image.prune/1`: the newest two per image name stay).

  Does nothing on a host without podman, and on an install that never built an
  image (no pins), so it is inert until the podman backend is in use.

  ## Configuration

  Via `config :arbiter, :worker_image_refresher`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests call `run_now/2`).
    * `:interval_ms` — how often to check (default one hour).
  """

  use GenServer

  require Logger

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Pins

  @default_interval_ms 60 * 60_000
  @run_timeout_ms 30 * 60_000

  @type outcome ::
          :not_due
          | {:ran,
             %{
               changed: [{String.t(), String.t(), String.t()}],
               failed: [{String.t(), String.t()}],
               pruned: %{removed: [String.t()], failed: [{String.t(), String.t()}]}
             }}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Refresh and prune now if due (or `force: true`). Other options are the
  `Pins` / `Image` ones (`:root`, `:runner`, `:now`).
  """
  @spec run_now(GenServer.server(), keyword()) :: outcome()
  def run_now(server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:run_now, opts}, @run_timeout_ms)

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms)
    }

    if state.enabled, do: schedule(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:run_now, opts}, _from, state), do: {:reply, run(opts), state}

  @impl true
  def handle_info(:tick, state) do
    if System.find_executable("podman") do
      try do
        _ = run([])
      rescue
        e -> Logger.warning("Worker.Image.Refresher: #{Exception.message(e)}")
      end
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run(opts) do
    if Keyword.get(opts, :force, false) or Pins.due?(opts) do
      %{changed: changed, failed: failed} = Pins.refresh(opts)

      Enum.each(changed, fn {ref, old, new} ->
        Logger.info(
          "Worker.Image: base #{ref} moved #{old} -> #{new}; images rebuild on next use"
        )
      end)

      Enum.each(failed, fn {ref, reason} ->
        Logger.warning("Worker.Image: could not refresh base #{ref}: #{reason}")
      end)

      {:ran, %{changed: changed, failed: failed, pruned: prune(opts)}}
    else
      :not_due
    end
  end

  defp prune(opts) do
    case Image.prune(opts) do
      {:ok, result} -> result
      {:error, reason} -> %{removed: [], failed: [{"(list)", reason}]}
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case Keyword.get(Application.get_env(:arbiter, :worker_image_refresher, []), key) do
      nil -> default
      val -> val
    end
  end
end
