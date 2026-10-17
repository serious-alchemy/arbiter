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

  With `layout: "playwright"` the name is the screenshot argument and the
  baseline is `<arg>-<project>-<platform>.png`. The project is read from the
  results directory name (the longest project known from the baselines that the
  directory ends with, after stripping a trailing `-retryN`). Retry directories
  of one snapshot and project are one snapshot: the last retry's actual is used
  and `max_snapshots` counts them once. Two different results directories for
  one project still refuse.
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
         :ok <- if(config.layout == "playwright", do: :ok, else: within_cap(actuals, config)),
         {:ok, entries} <- map_baselines(actuals, config, checkout),
         :ok <- within_cap(entries, config) do
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
        %{name: name, dir: results_dir(parts), bytes: bytes}
      end

    if found == [], do: {:error, :no_actuals}, else: {:ok, found}
  end

  defp results_dir(parts) do
    case Enum.drop(parts, -1) do
      [] -> ""
      dirs -> List.last(dirs)
    end
  end

  # Counted on the resolved snapshots, so retry copies of one snapshot are one.
  defp within_cap(entries, %{max_snapshots: max}) do
    if length(entries) > max, do: {:error, {:too_many, length(entries), max}}, else: :ok
  end

  defp map_baselines(actuals, config, checkout) do
    root = Path.join(checkout, config.baseline_dir)
    existing = if File.dir?(root), do: list_files(root), else: []

    with {:ok, resolved} <- resolve(actuals, config, existing) do
      resolved
      |> Enum.reduce_while({:ok, []}, fn {name, wanted, bytes}, {:ok, acc} ->
        case Enum.filter(existing, &wanted.(Path.basename(&1))) do
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
  end

  # One `{name, basename_matcher, bytes}` per snapshot to refresh.
  defp resolve(actuals, %{layout: "playwright"} = config, existing) do
    basenames = Enum.map(existing, &Path.basename/1)
    args = actuals |> Enum.map(& &1.name) |> Enum.uniq()

    actuals
    |> Enum.group_by(& &1.name)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {arg, group}, {:ok, acc} ->
      case playwright_group(arg, group, basenames, args, config) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve(actuals, config, _existing) do
    names = Enum.map(actuals, & &1.name)

    case Enum.find(names, &(Enum.count(names, fn n -> n == &1 end) > 1)) do
      nil ->
        {:ok,
         Enum.map(actuals, fn a ->
           wanted = a.name <> config.baseline_suffix
           {a.name, &(&1 == wanted), a.bytes}
         end)}

      dup ->
        {:error, {:duplicate_actual, dup}}
    end
  end

  defp playwright_group(arg, group, basenames, args, config) do
    tail = "-" <> config.platform <> ".png"

    projects =
      for base <- basenames,
          String.starts_with?(base, arg <> "-"),
          String.ends_with?(base, tail),
          project =
            base |> String.replace_prefix(arg <> "-", "") |> String.replace_suffix(tail, ""),
          project != "",
          not claimed_by_other_arg?(arg, project, args),
          uniq: true,
          do: project

    group
    |> Enum.map(fn a ->
      {base, retry} = split_retry(a.dir)

      project =
        projects
        |> Enum.filter(&project_of?(base, &1))
        |> Enum.max_by(&byte_size/1, fn -> nil end)

      {project, base, retry, a.bytes}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn
      {nil, _}, _ ->
        {:halt, {:error, {:no_baseline, arg}}}

      {project, runs}, {:ok, acc} ->
        case runs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
          [_one] ->
            {_, _, _, bytes} = Enum.max_by(runs, &elem(&1, 2))
            wanted = arg <> "-" <> project <> tail
            {:cont, {:ok, [{arg <> "-" <> project, &(&1 == wanted), bytes} | acc]}}

          _many ->
            {:halt, {:error, {:duplicate_actual, arg <> "-" <> project}}}
        end
    end)
  end

  # `patient-summary-mobile-dark-linux.png` read as arg `patient` gives the
  # project `summary-mobile-dark`; when the archive also has an actual named
  # `patient-summary`, that file belongs to it, not to `patient`.
  defp claimed_by_other_arg?(arg, project, args) do
    Enum.any?(args, fn other ->
      String.starts_with?(other, arg <> "-") and
        String.starts_with?(project, String.replace_prefix(other, arg <> "-", "") <> "-")
    end)
  end

  defp split_retry(dir) do
    case Regex.run(~r/^(.*)-retry(\d+)$/, dir) do
      [_, base, n] -> {base, String.to_integer(n)}
      _ -> {dir, 0}
    end
  end

  defp project_of?(dir, project), do: dir == project or String.ends_with?(dir, "-" <> project)

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
