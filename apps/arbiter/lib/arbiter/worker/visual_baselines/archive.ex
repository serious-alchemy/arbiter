defmodule Arbiter.Worker.VisualBaselines.Archive do
  @moduledoc """
  Turns a visual job's artifacts archive (a zip) into a plan of baseline
  replacements (bd-9obzu9, GitHub #936).

  The archive is untrusted data: nothing in it names a path that is written. A
  file is an *actual image* when it sits under `artifact_path` and its name ends
  in `actual_suffix`; its snapshot name is the rest of the file name. The
  destination is found in the checkout instead — the one file under
  `baseline_dir` called `<name><baseline_suffix>`. Anything that cannot be mapped
  to exactly one existing baseline refuses the whole plan (a new snapshot with no
  baseline, two baselines by the same name, two actuals for one snapshot): the
  caller then takes the normal fix path.
  """

  alias Arbiter.Worker.VisualBaselines.Config

  @type entry :: %{name: String.t(), baseline: String.t(), bytes: binary()}

  @type error ::
          :bad_archive
          | :no_actuals
          | :no_change
          | {:no_baseline, String.t()}
          | {:ambiguous_baseline, String.t()}
          | {:duplicate_actual, String.t()}
          | {:too_many, pos_integer(), pos_integer()}

  @doc """
  The baselines to overwrite, as repo-relative paths with the new bytes. Actuals
  already equal to their baseline are left out; `:no_change` when none differ.
  """
  @spec plan(binary(), Config.t(), String.t()) :: {:ok, [entry()]} | {:error, error()}
  def plan(archive, %Config{} = config, checkout) when is_binary(archive) do
    with {:ok, files} <- unzip(archive),
         {:ok, actuals} <- actuals(files, config),
         :ok <- within_cap(actuals, config),
         {:ok, entries} <- map_baselines(actuals, config, checkout) do
      case Enum.reject(entries, &unchanged?(&1, checkout)) do
        [] -> {:error, :no_change}
        changed -> {:ok, changed}
      end
    end
  end

  defp unzip(archive) do
    case :zip.unzip(archive, [:memory]) do
      {:ok, files} -> {:ok, Enum.map(files, fn {name, bytes} -> {to_string(name), bytes} end)}
      {:error, _} -> {:error, :bad_archive}
    end
  end

  defp actuals(files, config) do
    prefix = if config.artifact_path == "", do: [], else: Path.split(config.artifact_path)

    found =
      for {path, bytes} <- files,
          parts = Path.split(path),
          List.starts_with?(parts, prefix),
          base = List.last(parts),
          String.ends_with?(base, config.actual_suffix),
          name = String.replace_suffix(base, config.actual_suffix, ""),
          name != "" do
        {name, bytes}
      end

    names = Enum.map(found, &elem(&1, 0))

    cond do
      found == [] ->
        {:error, :no_actuals}

      dup = Enum.find(names, &(Enum.count(names, fn n -> n == &1 end) > 1)) ->
        {:error, {:duplicate_actual, dup}}

      true ->
        {:ok, found}
    end
  end

  defp within_cap(actuals, %{max_snapshots: max}) do
    if length(actuals) > max, do: {:error, {:too_many, length(actuals), max}}, else: :ok
  end

  defp map_baselines(actuals, config, checkout) do
    root = Path.join(checkout, config.baseline_dir)
    existing = if File.dir?(root), do: list_files(root), else: []

    Enum.reduce_while(actuals, {:ok, []}, fn {name, bytes}, {:ok, acc} ->
      wanted = name <> config.baseline_suffix

      case Enum.filter(existing, &(Path.basename(&1) == wanted)) do
        [one] ->
          rel = Path.relative_to(one, checkout)
          {:cont, {:ok, [%{name: name, baseline: rel, bytes: bytes} | acc]}}

        [] ->
          {:halt, {:error, {:no_baseline, name}}}

        _many ->
          {:halt, {:error, {:ambiguous_baseline, name}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp list_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      cond do
        File.lstat!(path).type == :symlink -> []
        File.dir?(path) -> list_files(path)
        true -> [path]
      end
    end)
  end

  defp unchanged?(%{baseline: rel, bytes: bytes}, checkout),
    do: File.read(Path.join(checkout, rel)) == {:ok, bytes}
end
