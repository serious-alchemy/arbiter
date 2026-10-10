defmodule Arbiter.NodeAgent.Protocol do
  @moduledoc """
  The node→primary payloads of the wire protocol, proto version 1
  (`docs/design/remote-workers.md` §4.2). Pure apart from reading `/proc` for
  the facts a `hello` and a heartbeat carry; every `/proc` read is best-effort
  and omitted when unavailable.

  The **bootstrap subset** (`hello`, `hello_ok`, `hb`, `hb_ack`, `upgrade`,
  `drain`, `rotate`) is frozen across all versions (§6), so a field here is only
  ever added.

  Contract with the primary half (RW6): the agent pushes `hello` after joining
  `node:<node_id>` and accepts `hello_ok` either as the push's reply or as a
  `hello_ok` push; it pushes `hb` every `hb_interval` seconds and accepts
  `hb_ack` either as a reply or as a push. In `hello_ok`, `hb_interval` and
  `fence_after` are **seconds**, and `upgrade` is `%{"version", "sha256"}`.
  """

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Retained

  @doc "The topic a node joins: `node:<node_id>`."
  @spec topic(Config.t()) :: String.t()
  def topic(%Config{node_id: node_id}), do: "node:" <> node_id

  @doc """
  The `hello` payload: version, proto, arch, capability flags, capacity facts,
  the inventory of live runs, and `readiness` (the `PodmanReadiness.diagnose/1`
  report).
  """
  @spec hello(Config.t(), map()) :: map()
  def hello(%Config{} = config, readiness) do
    %{
      "agent_version" => config.version,
      "proto" => Config.proto(),
      "kind" => "machine",
      "arch" => to_string(:erlang.system_info(:system_architecture)),
      # Only what this agent actually implements; later children add `bundle`, …
      # as they land.
      "caps" => %{
        "backend" => "podman",
        "image" => "build",
        "upgrade" => "tarball",
        "bridge_streams" => "mux",
        "run_hold" => "quiesce",
        "exec" => "run"
      },
      "capacity" => capacity(config),
      "inventory" => %{
        "runs" => live_runs(config),
        "retained" => Enum.map(Retained.list(config), &Retained.report/1)
      },
      "readiness" => readiness
    }
  end

  @doc "A heartbeat: per-run state, load and free memory."
  @spec heartbeat(Config.t(), non_neg_integer()) :: map()
  def heartbeat(%Config{} = config, seq) do
    %{"seq" => seq, "runs" => live_runs(config)}
    |> put_present("load", load())
    |> put_present("free_mem", meminfo("MemAvailable"))
  end

  @doc "The live runs the agent reports (`[]` until the run supervisor exists)."
  @spec live_runs(Config.t()) :: [map()]
  def live_runs(%Config{live_runs_fun: nil}), do: []
  def live_runs(%Config{live_runs_fun: fun}), do: fun.()

  # -- facts ------------------------------------------------------------------------

  # Facts plus the derived `suggestion` (computed here, agent-side, so the primary
  # only reads it) and the owner's `ceiling` (`ARB_NODE_MAX_WORKERS`) when set.
  defp capacity(%Config{} = config) do
    config.backend.capacity()
    |> put_present("ceiling", config.max_workers)
  end

  @doc "The host facts behind `capacity` (cpus, memory, suggestion), without the owner ceiling."
  @spec capacity_facts() :: map()
  def capacity_facts do
    %{cpus: cpus, mem_total: mem_total} = local_hardware()

    %{"cpus" => cpus, "suggestion" => suggestion(cpus, mem_total)}
    |> put_present("mem_total", mem_total)
  end

  @doc """
  This machine's CPU count and `MemTotal` in bytes (`nil` when unreadable): the
  two facts `suggestion/2` takes. The primary reads them for its own default cap
  (`Arbiter.Nodes.LocalCapacity`), the same way every node's `hello` reports them.
  """
  @spec local_hardware() :: %{cpus: pos_integer(), mem_total: non_neg_integer() | nil}
  def local_hardware do
    %{
      cpus: :erlang.system_info(:logical_processors_available) |> cpus(),
      mem_total: meminfo("MemTotal")
    }
  end

  @cpus_per_worker 2
  @worker_mem_cap 4 * 1024 * 1024 * 1024

  @doc """
  The node's worker suggestion (`docs/design/remote-workers.md` §13):
  `min(floor(cpus / #{@cpus_per_worker}), floor(0.8 × mem_total / 4 GiB))`, at least 1.
  `mem_total` in bytes; `nil` (unreadable) leaves the CPU term alone.
  """
  @spec suggestion(pos_integer(), non_neg_integer() | nil) :: pos_integer()
  def suggestion(cpus, mem_total) do
    by_cpu = div(cpus, @cpus_per_worker)
    by_mem = if mem_total, do: div(mem_total * 8, 10 * @worker_mem_cap), else: by_cpu
    max(1, min(by_cpu, by_mem))
  end

  defp cpus(:unknown), do: System.schedulers_online()
  defp cpus(n), do: n

  defp load do
    with {:ok, body} <- File.read("/proc/loadavg"),
         [one | _] <- String.split(body),
         {value, _} <- Float.parse(one) do
      value
    else
      _ -> nil
    end
  end

  # Bytes, from a `/proc/meminfo` line such as `MemAvailable:  1234 kB`.
  defp meminfo(key) do
    with {:ok, body} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^#{key}:\s+(\d+) kB/m, body) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
