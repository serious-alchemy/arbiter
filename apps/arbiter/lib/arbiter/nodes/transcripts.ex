defmodule Arbiter.Nodes.Transcripts do
  @moduledoc """
  The primary's **sanitising transcript extractor** (`docs/design/remote-workers.md`
  §7.6): a node uploads the run's `projects/**` session JSONL as a tar, and this
  puts it into the run's config dir (the same path the local readers use:
  `Usage.ClaudeSessionFile.locate/2`, `SessionArchive.archive_run/2`) without
  trusting a byte of the tar.

  The archive is listed first and judged **before anything is written**:

    * every entry's path must be relative, free of `..`, `.` and empty segments and
      NUL bytes: otherwise the whole archive is refused (`{:unsafe_path, name}`);
    * only regular files and directories: a link, device or anything else refuses
      the archive (`{:unsafe_entry, name, type}`);
    * only `*.jsonl` files under `projects/` (subagents live under
      `projects/<slug>/<session>/subagents/`) are extracted; any other regular file
      is skipped and reported in `skipped`, never extracted;
    * caps: entries (`max_entries`, default 20 000), bytes per file
      (`max_file_bytes`, 256 MiB) and in total (`max_bytes`, 512 MiB).

  Extraction goes to a staging directory beside the destination and each file is
  then moved into place, refusing any destination path that already has a symlink
  in it (`{:unsafe_destination, path}`).
  """

  @default_max_entries 20_000
  @default_max_file_bytes 256 * 1024 * 1024
  @default_max_bytes 512 * 1024 * 1024

  @type result ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer(), skipped: [String.t()]}}
          | {:error, term()}

  @doc "Extract the tar (plain or gzipped) at `tar_path` into `dest`. See the moduledoc."
  @spec extract(Path.t(), Path.t(), keyword()) :: result()
  def extract(tar_path, dest, opts \\ []) do
    limits = %{
      entries: Keyword.get(opts, :max_entries, @default_max_entries),
      file: Keyword.get(opts, :max_file_bytes, @default_max_file_bytes),
      total: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }

    with {:ok, entries} <- list(tar_path),
         {:ok, plan} <- plan(entries, limits),
         :ok <- check_destination(dest, plan.files) do
      move_in(tar_path, dest, plan)
    end
  end

  # ---- listing -----------------------------------------------------------------------

  defp list(tar_path) do
    case :erl_tar.table(String.to_charlist(tar_path), compression() ++ [:verbose]) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> retry_plain(tar_path, reason)
    end
  rescue
    e -> {:error, {:bad_archive, Exception.message(e)}}
  end

  # `:compressed` is tried first (a gzip magic number decides), plain otherwise.
  defp compression, do: [:compressed]

  defp retry_plain(tar_path, reason) do
    case :erl_tar.table(String.to_charlist(tar_path), [:verbose]) do
      {:ok, entries} -> {:ok, entries}
      {:error, _} -> {:error, {:bad_archive, inspect(reason)}}
    end
  end

  # ---- judging -----------------------------------------------------------------------

  defp plan(entries, limits) do
    if length(entries) > limits.entries do
      {:error, {:too_many_entries, length(entries)}}
    else
      entries
      |> Enum.reduce_while({:ok, %{files: [], skipped: [], bytes: 0}}, &judge(&1, &2, limits))
    end
  end

  defp judge({name, type, size, _mtime, _mode, _uid, _gid}, {:ok, acc}, limits) do
    with {:ok, path} <- safe_path(name),
         :ok <- allowed_type(path, type) do
      classify(path, type, size, acc, limits)
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp safe_path(name) do
    case :unicode.characters_to_binary(name) do
      path when is_binary(path) -> check_path(path)
      _ -> {:error, {:unsafe_path, inspect(name)}}
    end
  end

  defp check_path(path) do
    segments = path |> String.trim_trailing("/") |> String.split("/")

    bad? =
      path == "" or String.starts_with?(path, "/") or String.contains?(path, <<0>>) or
        Enum.any?(segments, &(&1 in ["", ".", ".."]))

    if bad?, do: {:error, {:unsafe_path, path}}, else: {:ok, String.trim_trailing(path, "/")}
  end

  defp allowed_type(_path, type) when type in [:regular, :directory], do: :ok
  defp allowed_type(path, type), do: {:error, {:unsafe_entry, path, type}}

  defp classify(_path, :directory, _size, acc, _limits), do: {:cont, {:ok, acc}}

  defp classify(path, :regular, size, acc, limits) do
    cond do
      not wanted?(path) ->
        {:cont, {:ok, %{acc | skipped: [path | acc.skipped]}}}

      size > limits.file ->
        {:halt, {:error, {:too_large, :file, path}}}

      acc.bytes + size > limits.total ->
        {:halt, {:error, {:too_large, :total, acc.bytes + size}}}

      true ->
        {:cont, {:ok, %{acc | files: [path | acc.files], bytes: acc.bytes + size}}}
    end
  end

  defp wanted?(path), do: String.starts_with?(path, "projects/") and String.ends_with?(path, ".jsonl")

  # ---- writing -----------------------------------------------------------------------

  # No component of any destination, from `dest` down, may be a symlink.
  defp check_destination(dest, files) do
    Enum.find_value(files, :ok, fn file ->
      case symlink_in(dest, Path.dirname(file)) do
        nil -> if symlink?(Path.join(dest, file)), do: {:error, {:unsafe_destination, file}}
        path -> {:error, {:unsafe_destination, path}}
      end
    end)
  end

  defp symlink_in(dest, rel_dir) do
    rel_dir
    |> Path.split()
    |> Enum.reduce_while({dest, nil}, fn segment, {dir, _} ->
      path = Path.join(dir, segment)
      if symlink?(path), do: {:halt, {path, path}}, else: {:cont, {path, nil}}
    end)
    |> elem(1)
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))

  defp move_in(_tar, _dest, %{files: []} = plan),
    do: {:ok, %{files: 0, bytes: 0, skipped: Enum.reverse(plan.skipped)}}

  defp move_in(tar_path, dest, plan) do
    File.mkdir_p!(dest)
    staging = Path.join(dest, ".extract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(staging)

    try do
      names = Enum.map(plan.files, &String.to_charlist/1)

      case :erl_tar.extract(String.to_charlist(tar_path), [{:cwd, String.to_charlist(staging)}, {:files, names}] ++ compression()) do
        :ok -> place(staging, dest, plan)
        {:error, _} -> extract_plain(tar_path, staging, dest, plan, names)
      end
    after
      File.rm_rf(staging)
    end
  end

  defp extract_plain(tar_path, staging, dest, plan, names) do
    case :erl_tar.extract(String.to_charlist(tar_path), [{:cwd, String.to_charlist(staging)}, {:files, names}]) do
      :ok -> place(staging, dest, plan)
      {:error, reason} -> {:error, {:bad_archive, inspect(reason)}}
    end
  end

  defp place(staging, dest, plan) do
    Enum.each(plan.files, fn file ->
      from = Path.join(staging, file)
      to = Path.join(dest, file)

      # A regular file, by lstat: whatever the tar named, a link never gets placed.
      with {:ok, %File.Stat{type: :regular}} <- File.lstat(from) do
        File.mkdir_p!(Path.dirname(to))
        File.rename!(from, to)
        File.chmod(to, 0o600)
      end
    end)

    {:ok, %{files: length(plan.files), bytes: plan.bytes, skipped: Enum.reverse(plan.skipped)}}
  end
end
