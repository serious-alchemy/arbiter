defmodule Arbiter.Worker.RunTmp do
  @moduledoc """
  Per-run `TMPDIR` for worker/agent children (bd-5ad4ch, GitHub #231).

  `/tmp` is tmpfs (RAM) on the dogfood host, and agents that invent their own
  `/tmp/<name>` scratch dirs filled it with 11 GB of leftovers from finished
  runs. Arbiter instead creates one directory per run under
  `Arbiter.Config.Paths.worker_tmp_root/0` (disk-backed), hands it to the child
  as `TMPDIR`/`TMP`/`TEMP`, removes it when the run's worker terminates
  (`remove/1`, whatever the outcome), and sweeps orphans left by runs that died
  with the server (`sweep/1`, run at boot by `Arbiter.Worker.RunTmp.Sweeper`).

  Removal is `force_rm_rf/1`: some fixtures leave read-only directories or
  files that a plain `File.rm_rf/1` cannot delete, so the tree is made writable
  first.
  """

  alias Arbiter.Config.Paths

  @default_sweep_max_age_ms 24 * 60 * 60_000
  @default_warn_bytes 5 * 1024 * 1024 * 1024

  @doc "Create a fresh per-run directory for `task_id` and return its path."
  @spec create(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def create(task_id) do
    slug =
      (task_id || "run")
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.slice(0, 40)

    dir =
      Path.join(
        Paths.worker_tmp_root(),
        "#{slug}-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
      )

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:worker_tmp_unavailable, dir, reason}}
    end
  end

  @doc "Env pairs that point a child's temp lookups at `dir`."
  @spec env_pairs(String.t() | nil) :: [{String.t(), String.t()}]
  def env_pairs(nil), do: []
  def env_pairs(dir), do: [{"TMPDIR", dir}, {"TMP", dir}, {"TEMP", dir}]

  @doc """
  Remove a per-run directory. Refuses anything not strictly inside the worker
  temp root, so a bad path can never delete outside it.
  """
  @spec remove(String.t() | nil) :: :ok
  def remove(nil), do: :ok

  def remove(dir) when is_binary(dir) do
    if inside_root?(dir) do
      _ = Arbiter.Worker.SessionHistory.preserve(dir)
      force_rm_rf(dir)
    end

    :ok
  end

  @doc "`File.rm_rf/1` that first makes the whole tree writable."
  @spec force_rm_rf(String.t()) :: :ok
  def force_rm_rf(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, entries} -> Enum.each(entries, &force_rm_rf(Path.join(path, &1)))
          _ -> :ok
        end

        _ = File.rmdir(path)
        :ok

      {:ok, _} ->
        _ = File.rm(path)
        :ok

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Remove every direct child of the worker temp root whose mtime is older than
  `:max_age_ms` (default one day). Returns the removed paths.
  """
  @spec sweep(keyword()) :: [String.t()]
  def sweep(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &Paths.worker_tmp_root/0)
    max_age_ms = Keyword.get(opts, :max_age_ms, @default_sweep_max_age_ms)
    cutoff = System.os_time(:second) - div(max_age_ms, 1000)

    case File.ls(root) do
      {:ok, entries} ->
        for entry <- entries,
            path = Path.join(root, entry),
            stale?(path, cutoff) do
          _ = Arbiter.Worker.SessionHistory.preserve(path)
          force_rm_rf(path)
          path
        end

      {:error, _} ->
        []
    end
  end

  @doc """
  Health report for the doctor check: where the worker temp root lives, whether
  that filesystem is RAM-backed (`tmpfs`/`ramfs`), and how much it holds.

  Returns `%{root:, tmpfs: boolean, size_bytes:, threshold_bytes:, over_threshold:,
  fstype:}`. The threshold is `config :arbiter, :run_tmp_sweeper,
  warn_bytes:` (default 5 GiB).
  """
  @spec diagnosis(keyword()) :: map()
  def diagnosis(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &Paths.worker_tmp_root/0)
    mountinfo = Keyword.get_lazy(opts, :mountinfo, &read_mountinfo/0)

    threshold =
      Keyword.get(
        opts,
        :warn_bytes,
        :arbiter
        |> Application.get_env(:run_tmp_sweeper, [])
        |> Keyword.get(:warn_bytes, @default_warn_bytes)
      )

    fstype = fstype_for(root, mountinfo)
    size = tree_size(root)

    %{
      root: root,
      fstype: fstype,
      tmpfs: fstype in ["tmpfs", "ramfs"],
      size_bytes: size,
      threshold_bytes: threshold,
      over_threshold: size > threshold
    }
  end

  defp read_mountinfo do
    case File.read("/proc/self/mountinfo") do
      {:ok, text} -> text
      _ -> ""
    end
  end

  # Longest mount point that prefixes `path` wins. mountinfo lines look like
  # `36 35 98:0 / /mnt rw,noatime - ext4 /dev/sda1 rw`: field 5 is the mount
  # point, and the fstype follows the ` - ` separator.
  defp fstype_for(path, mountinfo) do
    path = Path.expand(path)

    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      with [pre, post] <- String.split(line, " - ", parts: 2),
           [_, _, _, _, mount | _] <- String.split(pre, " "),
           [fstype | _] <- String.split(post, " ") do
        mount = String.replace(mount, "\\040", " ")
        [{mount, fstype}]
      else
        _ -> []
      end
    end)
    |> Enum.filter(fn {mount, _} ->
      mount == "/" or path == mount or String.starts_with?(path, mount <> "/")
    end)
    |> Enum.max_by(fn {mount, _} -> String.length(mount) end, fn -> nil end)
    |> case do
      {_, fstype} -> fstype
      nil -> nil
    end
  end

  defp tree_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> entries |> Enum.map(&tree_size(Path.join(path, &1))) |> Enum.sum()
          _ -> 0
        end

      {:ok, %File.Stat{size: size}} ->
        size

      _ ->
        0
    end
  end

  defp stale?(path, cutoff_unix) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < cutoff_unix
      _ -> false
    end
  end

  defp inside_root?(dir) do
    root = Path.expand(Paths.worker_tmp_root())
    expanded = Path.expand(dir)
    expanded != root and String.starts_with?(expanded, root <> "/")
  end
end
