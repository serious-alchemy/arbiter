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
      # Only what this agent actually implements; later children add `bundle`,
      # `bridge_streams`, … as they land.
      "caps" => %{"backend" => "podman", "image" => "build", "upgrade" => "tarball"},
      "capacity" => capacity(),
      "inventory" => %{"runs" => live_runs(config)},
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

  defp capacity do
    %{"cpus" => :erlang.system_info(:logical_processors_available) |> cpus()}
    |> put_present("mem_total", meminfo("MemTotal"))
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
