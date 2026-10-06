defmodule Arbiter.NodeAgent.Status do
  @moduledoc """
  What `arbiter-node status` shows: a small JSON file, `<node_home>/status.json`,
  rewritten atomically (temp file + rename) on every change. One process owns it,
  so the connection and the upgrader never interleave writes.

  Not a secret: the file holds the primary's URL, versions and states, never the
  credential.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :path),
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc "Merge `changes` (string- or atom-keyed) into the status and write it."
  @spec put(GenServer.server(), map()) :: :ok
  def put(server \\ __MODULE__, changes) when is_map(changes),
    do: GenServer.call(server, {:put, changes})

  @doc "The current status map (string keys)."
  @spec get(GenServer.server()) :: map()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @doc "Write `status` to `path` atomically. Used directly when no agent is running."
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, status) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(status, pretty: true) <> "\n"),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  @impl true
  def init(path), do: {:ok, %{path: path, status: %{"pid" => System.pid()}}}

  @impl true
  def handle_call({:put, changes}, _from, state) do
    status =
      changes
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> then(&Map.merge(state.status, &1))
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    _ = write(state.path, status)
    {:reply, :ok, %{state | status: status}}
  end

  def handle_call(:get, _from, state), do: {:reply, state.status, state}
end
