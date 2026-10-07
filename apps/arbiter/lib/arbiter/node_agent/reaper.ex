defmodule Arbiter.NodeAgent.Reaper do
  @moduledoc """
  The node-side reaper (`docs/design/remote-workers.md` §10.6): it removes the
  leftovers of runs the primary no longer has, **install-scoped** and driven by
  the primary's **live set**.

  The primary sends `reap{install, live_set}` on every `hello` and periodically,
  and only when it is the single primary instance (`SingleInstance.primary?/1`).
  Nothing here reaps on its own initiative: a node that cannot reach its primary
  keeps everything, because that is also what a partition looks like.

  Scope, in order of how hard it is to undo:

    * **Containers and test-services pods** carrying this node's `arbiter.node`
      label **and** the asking install's `arbiter.install` label, whose
      `arbiter.run` is outside the live set and the agent's own run table, are
      removed at once. The labels are re-checked on what `podman ps` returns, not
      only in the filter, so a node enrolled to two installs can never sweep the
      other's containers. A pod is judged by that live set, never by
      `TestServices.os_alive?/1` (its recorded pid is the agent's own BEAM).
    * **Run directories** (shadow clones, retained bundles) outside the live set
      are removed only past a minimum age (24 h, against `WorktreeSweeper`'s 1 h
      locally): they may hold the only copy of un-checkpointed work.
    * **Secrets files** under the runtime dir for runs that are not live.

  An empty or missing install id reaps nothing.
  """

  alias Arbiter.NodeAgent.{Config, Runs, Secrets}
  alias Arbiter.Worker.{Container, TestServices}

  require Logger

  @default_min_age_s 24 * 60 * 60
  @timeout_ms 30_000

  @type request :: %{install: String.t() | nil, live_set: [String.t()]}
  @type result :: %{containers: [String.t()], pods: [String.t()], dirs: [String.t()]}

  @doc """
  Reap against `request`. Options: `:min_age_s`, `:runner`, `:podman`,
  `:runtime_dir` (the secrets root) and `:own_runs` (default: the run table).
  """
  @spec reap(Config.t(), request(), keyword()) :: result() | {:error, :no_install}
  def reap(%Config{} = config, %{install: install, live_set: live_set}, opts \\ [])
      when is_list(live_set) do
    if is_binary(install) and install != "" do
      live = MapSet.new(live_set ++ Keyword.get_lazy(opts, :own_runs, &Runs.run_ids/0))
      labels = [{"arbiter.install", install}, {"arbiter.node", config.node_id}]

      result = %{
        containers: containers(labels, live, opts),
        pods: pods(labels, live, opts),
        dirs: dirs(config, live, opts)
      }

      secrets(live, opts)
      log(result)
      result
    else
      {:error, :no_install}
    end
  end

  # ---- containers ---------------------------------------------------------------

  defp containers(labels, live, opts) do
    filters = Enum.flat_map(labels, fn {k, v} -> ["--filter", "label=#{k}=#{v}"] end)

    case podman(opts, ["ps", "-a"] ++ filters ++ ["--format", "json"]) do
      {out, 0} -> out |> decode() |> Enum.flat_map(&orphan_container(&1, labels, live, opts))
      _ -> []
    end
  end

  defp orphan_container(%{"Names" => [name | _], "Labels" => %{} = found}, labels, live, opts)
       when is_binary(name) do
    ours? = Enum.all?(labels, fn {k, v} -> found[k] == v end)
    run = found["arbiter.run"]

    if ours? and String.starts_with?(name, "arb-") and is_binary(run) and
         not MapSet.member?(live, run) and remove(name, opts),
       do: [name],
       else: []
  end

  defp orphan_container(_other, _labels, _live, _opts), do: []

  defp remove(name, opts) do
    case Container.stop(name, podman_opts(opts)) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("node agent reaper: could not remove #{name}: #{inspect(reason)}")
        false
    end
  end

  # ---- pods ---------------------------------------------------------------------

  defp pods(labels, live, opts) do
    live? = fn pod -> MapSet.member?(live, get_in(pod, ["Labels", "arbiter.run"])) end

    TestServices.reap_orphans(podman_opts(opts) ++ [live_pods: live?, labels: labels])
  end

  # ---- directories --------------------------------------------------------------

  defp dirs(%Config{node_home: home}, live, opts) do
    min_age_s = Keyword.get(opts, :min_age_s, @default_min_age_s)
    cutoff = System.os_time(:second) - min_age_s
    root = Path.join(home, "runs")

    case File.ls(root) do
      {:ok, runs} ->
        for run <- Enum.sort(runs),
            not MapSet.member?(live, run),
            dir = Path.join(root, run),
            aged?(dir, cutoff),
            removed?(dir),
            do: run

      {:error, _} ->
        []
    end
  end

  defp removed?(dir), do: match?({:ok, _}, File.rm_rf(dir))

  defp aged?(dir, cutoff) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} -> mtime <= cutoff
      _ -> false
    end
  end

  # ---- secrets ------------------------------------------------------------------

  defp secrets(live, opts) do
    with {:ok, dir} <- Secrets.runtime_dir(Keyword.take(opts, [:runtime_dir])) do
      for run <- Secrets.runs(dir), not MapSet.member?(live, run), do: Secrets.remove(dir, run)
    end

    :ok
  end

  # ---- plumbing -----------------------------------------------------------------

  defp podman(opts, args) do
    Container.cmd(
      Keyword.take(opts, [:runner]),
      Keyword.get(opts, :podman) || System.find_executable("podman") || "podman",
      args,
      timeout: @timeout_ms
    )
  end

  defp podman_opts(opts), do: Keyword.take(opts, [:runner, :podman])

  defp decode(out) do
    case Jason.decode(out) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp log(%{containers: [], pods: [], dirs: []}), do: :ok

  defp log(result) do
    Logger.info(
      "node agent reaper: removed containers=#{inspect(result.containers)} " <>
        "pods=#{inspect(result.pods)} run dirs=#{inspect(result.dirs)}"
    )
  end
end
