defmodule Arbiter.NodeAgent.ImageGC do
  @moduledoc """
  Garbage collection of the worker images a machine node pulled (SI6,
  `docs/design/remote-workers.md` §21.4, "GC on the node").

  The node's owner owns the machine and its podman store. This module therefore
  removes **only what the agent pulled itself**, and only one way.

    * **A ledger.** `<node_home>/images.json` lists every digest the agent pulled:
      the reference, its repository, when it was pulled, when a run last used it,
      the runs that used it, its size and the seed-layer directory (the deps cache
      entry) extracted from it. An image that was already on the node when a run
      asked for it was not pulled by the agent and is never entered. GC reads the
      ledger and nothing else, so an image the owner pulled, or anything else in
      the store, is out of reach by construction. `legacy_prefix` images
      (`localhost/arbiter-dev/*`, the node-built images of the old plan path) are
      refused by name as well, and only **listed** (`hb.images.legacy`, the doctor).

    * **Never removed** (`plan/4`): a digest a live or preparing run uses (any run
      in the agent's run table), a retained run (`Arbiter.NodeAgent.Retained`) used,
      one `Arbiter.NodeAgent.Exec` still keeps a gate context for, one pulled or used
      in the last 24 h (`grace_s`: covers a worker between two opens of its run).

    * **Kept**: the newest two digests per repository by last use.

    * **Pressure** (graph root free below 15 % or 20 GiB): the 24 h grace is dropped
      and only what a live, preparing, retained or gate run needs, plus the newest
      digest per repository, survives. If the root is still under the line afterwards
      the heartbeat says so (`pressure_unrelieved`) and the doctor warns.

    * **How**: `podman rmi <ref>` of the digest reference, never `-f`, never any
      `prune` (which would take the owner's own dangling images too). An image podman
      refuses to remove (a container still uses it) stays in the ledger. A seed layer's
      deps cache entry (`<node_home>/deps-cache/layer-*`) goes when no kept image uses
      it.

    * **When**: hourly, after each pull, and when `collect/1` is called.

  `claim/2` and `pulled/2` are what `Arbiter.NodeAgent.ImagePull` calls, and
  `seed/2` what the run calls after installing deps from a layer. GC runs inside
  the server, so a claim waits for a running collection and a run can never start
  on an image that is being removed.
  """

  use GenServer

  alias Arbiter.NodeAgent.{Exec, Retained, Runs, SeedLayer}
  alias Arbiter.Worker.Container

  require Logger

  @legacy_prefix "localhost/arbiter-dev/"
  @grace_s 24 * 60 * 60
  @keep_normal 2
  @keep_pressure 1
  @interval_ms 60 * 60 * 1000
  @quick_timeout_ms 60_000
  @rmi_timeout_ms 10 * 60_000
  @reported_digests 32
  @min_free_ratio 0.15
  @min_free_bytes 20 * 1024 * 1024 * 1024
  @call_timeout_ms 15 * 60_000

  @type entry :: %{String.t() => term()}
  @type plan :: %{remove: [String.t()], keep: %{String.t() => atom()}}

  def legacy_prefix, do: @legacy_prefix

  # -- client ----------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  A run is about to use `ref`: if the ledger has it, record the use (so neither the
  24 h rule nor an in-flight collection can lose it). Always `:ok`; with no GC
  process (a test, a cluster controller) it does nothing.
  """
  @spec claim(String.t(), String.t(), keyword()) :: :ok
  def claim(ref, run, opts \\ []), do: call({:claim, ref, run}, opts)

  @doc "The agent pulled `ref` for `run`: enter it in the ledger and schedule a collection."
  @spec pulled(String.t(), String.t(), keyword()) :: :ok
  def pulled(ref, run, opts \\ []), do: call({:pulled, ref, run}, opts)

  @doc "`ref`'s seed layer was extracted into `<deps-cache>/<layer_dir>`."
  @spec seed(String.t(), String.t(), keyword()) :: :ok
  def seed(ref, layer_dir, opts \\ []), do: call({:seed, ref, layer_dir}, opts)

  @doc "Collect now. Returns what was removed and the pressure verdict."
  @spec collect(keyword()) :: {:ok, map()} | {:error, :not_running}
  def collect(opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      :collect,
      Keyword.get(opts, :timeout, @call_timeout_ms)
    )
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  What the heartbeat reports as `images`, or `nil` before the first collection or
  with no GC process. Read from a cache: it never waits for a collection.
  """
  @spec stats(keyword()) :: map() | nil
  def stats(opts \\ []) do
    :persistent_term.get({__MODULE__, Keyword.get(opts, :name, __MODULE__)}, nil)
  end

  defp call(message, opts) do
    GenServer.call(
      Keyword.get(opts, :name, __MODULE__),
      message,
      Keyword.get(opts, :timeout, @call_timeout_ms)
    )
  catch
    :exit, _ -> :ok
  end

  # -- pure core -------------------------------------------------------------------------

  @doc """
  Decide what a collection removes.

  `entries` is the ledger (`%{ref => entry}`), `ctx` is
  `%{now: unix, live_runs: [run], retained_runs: [run], gate_images: [ref]}`;
  `opts` are `pressure?: boolean` and `grace_s`. Returns `%{remove: [ref], keep:
  %{ref => reason}}` where every ledger entry appears once, as removed or as kept for
  a reason (`:live`, `:retained`, `:gate`, `:recent`, `:newest`).
  """
  @spec plan(%{String.t() => entry()}, map(), keyword()) :: plan()
  def plan(entries, ctx, opts \\ []) do
    pressure? = Keyword.get(opts, :pressure?, false)
    grace_s = Keyword.get(opts, :grace_s, @grace_s)
    keep_n = if pressure?, do: @keep_pressure, else: @keep_normal

    newest =
      entries
      |> Map.values()
      |> Enum.group_by(& &1["repo"])
      |> Enum.flat_map(fn {_repo, group} ->
        group |> Enum.sort_by(&recency/1, :desc) |> Enum.take(keep_n) |> Enum.map(& &1["ref"])
      end)
      |> MapSet.new()

    sets = %{
      live: MapSet.new(ctx.live_runs),
      retained: MapSet.new(ctx.retained_runs),
      gate: MapSet.new(ctx.gate_images),
      newest: newest
    }

    recent_cutoff = if pressure?, do: nil, else: ctx.now - grace_s

    keep =
      for {ref, entry} <- entries, into: %{} do
        {ref, keep_reason(ref, entry, sets, recent_cutoff)}
      end

    %{
      remove: for({ref, nil} <- keep, do: ref) |> Enum.sort(),
      keep: for({ref, reason} <- keep, reason != nil, into: %{}, do: {ref, reason})
    }
  end

  # `recent_cutoff` is nil under pressure: the grace is dropped.
  defp keep_reason(ref, entry, sets, recent_cutoff) do
    cond do
      legacy?(ref) -> :legacy
      reason = in_use(ref, entry["runs"] || [], sets) -> reason
      recent_cutoff != nil and recency(entry) > recent_cutoff -> :recent
      MapSet.member?(sets.newest, ref) -> :newest
      true -> nil
    end
  end

  defp in_use(ref, runs, sets) do
    cond do
      Enum.any?(runs, &MapSet.member?(sets.live, &1)) -> :live
      Enum.any?(runs, &MapSet.member?(sets.retained, &1)) -> :retained
      MapSet.member?(sets.gate, ref) -> :gate
      true -> nil
    end
  end

  defp recency(entry), do: max(entry["last_used"] || 0, entry["pulled_at"] || 0)

  defp legacy?(ref), do: String.starts_with?(ref, @legacy_prefix)

  @doc "Whether free space on the graph root is under the line (15 % or 20 GiB)."
  @spec pressure?(non_neg_integer(), non_neg_integer()) :: boolean()
  def pressure?(total, avail) when total > 0,
    do: avail / total < @min_free_ratio or avail < @min_free_bytes

  def pressure?(_total, _avail), do: false

  @doc "The repository of a reference: everything before its digest (or tag)."
  @spec repo(String.t()) :: String.t()
  def repo(ref) do
    [name | _] = String.split(ref, "@", parts: 2)
    # a tag is a `:` after the last `/`
    case Regex.run(~r{^(.*/[^/:]+|[^/:]+):[^/]+$}, name) do
      [_, bare] -> bare
      _ -> name
    end
  end

  # -- server ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval_ms, @interval_ms)

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      config: config,
      path: Path.join(config.node_home, "images.json"),
      deps_root: Path.join(config.node_home, "deps-cache"),
      opts: opts,
      interval: interval,
      entries: load(Path.join(config.node_home, "images.json")),
      pressure: false,
      unrelieved: false,
      legacy: [],
      timer: nil
    }

    publish(state)
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call({:claim, ref, run}, _from, state) do
    state =
      case state.entries do
        %{^ref => entry} ->
          put_entry(state, ref, touch(entry, run, now(state)))

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:pulled, ref, run}, _from, state) do
    now = now(state)

    entry =
      Map.get(state.entries, ref) ||
        %{
          "ref" => ref,
          "repo" => repo(ref),
          "pulled_at" => now,
          "last_used" => now,
          "runs" => [],
          "size" => image_size(ref, state),
          "seed" => nil
        }

    state = put_entry(state, ref, touch(entry, run, now))
    if Keyword.get(state.opts, :collect_on_pull, true), do: send(self(), :collect)
    {:reply, :ok, state}
  end

  def handle_call({:seed, ref, layer_dir}, _from, state) do
    state =
      case state.entries do
        %{^ref => entry} -> put_entry(state, ref, Map.put(entry, "seed", layer_dir))
        _ -> state
      end

    {:reply, :ok, state}
  end

  def handle_call(:collect, _from, state) do
    {result, state} = do_collect(state)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_info(:collect, state) do
    {_result, state} = do_collect(state)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    {_result, state} = do_collect(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{interval: :infinity} = state), do: state

  defp schedule(state),
    do: %{state | timer: Process.send_after(self(), :tick, state.interval)}

  # -- collection ------------------------------------------------------------------------

  defp do_collect(state) do
    pressure? = pressure_now?(state)
    ctx = context(state)
    plan = plan(state.entries, ctx, pressure?: pressure?, grace_s: grace_s(state))

    removed =
      plan.remove
      |> Enum.filter(&(removable?(&1, state) and rmi(&1, state)))

    entries = Map.drop(state.entries, removed)
    entries = prune_runs(entries, ctx)
    seeds_removed = drop_seeds(state, state.entries, entries, removed)
    unrelieved = pressure? and pressure_now?(state)
    state = %{state | entries: entries, pressure: pressure?, unrelieved: unrelieved}
    state = %{state | legacy: legacy_images(state)}
    persist(state)
    publish(state)

    {%{
       removed: removed,
       seeds_removed: seeds_removed,
       kept: Map.drop(plan.keep, removed),
       pressure: pressure?,
       pressure_unrelieved: unrelieved
     }, state}
  end

  # Defence in depth: a ref only reaches `rmi` if the ledger lists it and it is not a
  # legacy image.
  defp removable?(ref, state), do: Map.has_key?(state.entries, ref) and not legacy?(ref)

  defp rmi(ref, state) do
    case podman(state, ["rmi", ref], @rmi_timeout_ms) do
      {_, 0} ->
        Logger.info("NodeAgent.ImageGC: removed #{ref}")
        true

      {out, status} ->
        # Podman refuses an image a container still uses; that is the safe answer.
        # An image already gone is the goal reached.
        gone? = String.contains?(out, "image not known") or String.contains?(out, "no such image")

        if not gone?,
          do:
            Logger.info(
              "NodeAgent.ImageGC: #{ref} kept (podman rmi exited #{status}): #{String.slice(out, 0, 200)}"
            )

        gone?
    end
  end

  # Drop the seed-layer directories no remaining image uses.
  defp drop_seeds(state, before, remaining, removed) do
    still_used =
      remaining
      |> Map.values()
      |> Enum.map(& &1["seed"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    for ref <- removed,
        seed = get_in(before, [ref, "seed"]),
        is_binary(seed),
        not MapSet.member?(still_used, seed),
        reduce: [] do
      acc ->
        case SeedLayer.remove_layer(state.deps_root, seed) do
          :ok -> [seed | acc]
          _ -> acc
        end
    end
    |> Enum.reverse()
  end

  defp prune_runs(entries, ctx) do
    active = MapSet.new(ctx.live_runs ++ ctx.retained_runs)

    Map.new(entries, fn {ref, entry} ->
      {ref, Map.update(entry, "runs", [], fn runs -> Enum.filter(runs, &(&1 in active)) end)}
    end)
  end

  defp context(state) do
    %{
      now: now(state),
      live_runs: fetch(state, :runs_fun, &Runs.run_ids/0),
      retained_runs: retained_runs(state),
      gate_images: fetch(state, :gate_fun, &Exec.images/0)
    }
  end

  defp retained_runs(state) do
    fun = Keyword.get(state.opts, :retained_fun, fn -> Retained.list(state.config) end)
    for %{"run" => run} <- fun.(), is_binary(run), do: run
  rescue
    _ -> []
  end

  defp fetch(state, key, default) do
    Keyword.get(state.opts, key, default).()
  rescue
    _ -> []
  end

  defp grace_s(state), do: Keyword.get(state.opts, :grace_s, @grace_s)

  # -- ledger ----------------------------------------------------------------------------

  defp touch(entry, run, now) do
    entry
    |> Map.put("last_used", now)
    |> Map.update("runs", [run], fn runs -> Enum.uniq([run | runs]) end)
  end

  defp put_entry(state, ref, entry) do
    state = %{state | entries: Map.put(state.entries, ref, entry)}
    persist(state)
    publish(state)
    state
  end

  defp load(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"images" => images}} when is_list(images) <- Jason.decode(text) do
      for %{"ref" => ref} = entry <- images, is_binary(ref), into: %{}, do: {ref, entry}
    else
      _ -> %{}
    end
  end

  defp persist(state) do
    File.mkdir_p!(Path.dirname(state.path))
    tmp = state.path <> ".tmp"

    body =
      Jason.encode!(%{
        "images" => state.entries |> Map.values() |> Enum.sort_by(& &1["ref"])
      })

    File.write!(tmp, body)
    File.rename!(tmp, state.path)
  rescue
    e -> Logger.warning("NodeAgent.ImageGC: cannot write the ledger: #{Exception.message(e)}")
  end

  defp publish(state) do
    entries = Map.values(state.entries)

    stats =
      %{
        "count" => length(entries),
        "bytes" => entries |> Enum.map(&(&1["size"] || 0)) |> Enum.sum(),
        "digests" =>
          entries
          |> Enum.sort_by(&recency/1, :desc)
          |> Enum.take(@reported_digests)
          |> Enum.map(& &1["ref"]),
        "pressure" => state.pressure,
        "pressure_unrelieved" => state.unrelieved,
        "legacy" => state.legacy
      }

    :persistent_term.put({__MODULE__, state.name}, stats)
  end

  # -- podman ----------------------------------------------------------------------------

  defp image_size(ref, state) do
    case podman(state, ["image", "inspect", "--format", "{{.Size}}", ref], @quick_timeout_ms) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, _} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp legacy_images(state) do
    case podman(
           state,
           [
             "image",
             "ls",
             "--filter",
             "reference=#{@legacy_prefix}*",
             "--format",
             "{{.Repository}}:{{.Tag}}"
           ],
           @quick_timeout_ms
         ) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.filter(&legacy?/1) |> Enum.sort()

      _ ->
        state.legacy
    end
  end

  # Free space on podman's graph root: `podman info` names it, `df` measures it.
  defp pressure_now?(state) do
    case Keyword.fetch(state.opts, :space_fun) do
      {:ok, fun} ->
        {total, avail} = fun.()
        pressure?(total, avail)

      :error ->
        with {root, 0} <-
               podman(state, ["info", "--format", "{{.Store.GraphRoot}}"], @quick_timeout_ms),
             root = String.trim(root),
             true <- root != "",
             {out, 0} <- df(root, state),
             {total, avail} <- parse_df(out) do
          pressure?(total, avail)
        else
          _ -> false
        end
    end
  end

  defp df(root, state) do
    Container.cmd(Keyword.take(state.opts, [:runner]), "df", ["-Pk", root],
      timeout: @quick_timeout_ms,
      stderr_to_stdout: true
    )
  end

  @doc false
  def parse_df(out) do
    with [_header, line | _] <- String.split(out, "\n", trim: true),
         [_fs, total, _used, avail | _] <- String.split(line),
         {t, _} <- Integer.parse(total),
         {a, _} <- Integer.parse(avail) do
      {t * 1024, a * 1024}
    else
      _ -> nil
    end
  end

  defp podman(state, args, timeout) do
    podman = Keyword.get(state.opts, :podman) || System.find_executable("podman") || "podman"

    Container.cmd(Keyword.take(state.opts, [:runner]), podman, args,
      timeout: timeout,
      stderr_to_stdout: true
    )
  end

  defp now(state), do: Keyword.get(state.opts, :now_fun, fn -> System.os_time(:second) end).()

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end
end
