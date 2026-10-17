defmodule Arbiter.Worker.VisualBaselines.Config do
  @moduledoc """
  The `worker.repos.<repo>.visual_baselines` block (bd-9obzu9, GitHub #936).

  Resolves like every other per-repo `worker.*` key:
  `worker.repos.<repo>.visual_baselines` is merged over `worker.visual_baselines`, the repo's keys
  winning. Nothing set at either level means the feature is off (`:none`).

      {"worker": {"repos": {"tonic": {"visual_baselines": {
        "job": "visual",
        "artifact_path": "test-results",
        "actual_suffix": "-actual.png",
        "baseline_dir": "e2e/visual.spec.ts-snapshots",
        "baseline_suffix": "-chromium-linux.png",
        "ignore_paths": ["docs/**", "**/*.md"]
      }}}}}

  Keys:

    * `job` (required) — the CI job that takes the screenshots.
    * `artifact` — GitHub only: the name of the Actions artifact that job uploads
      (GitLab reads the job's own artifacts archive).
    * `artifact_path` — directory inside the archive holding the actual images
      (default: the archive root). Searched recursively.
    * `actual_suffix` — a file in the archive is an actual image when its name ends
      in this (default `-actual.png`); the rest of the name is the snapshot's name.
    * `baseline_dir` (required) — repo-relative directory holding the baselines;
      searched recursively, so per-spec `*-snapshots` directories work.
    * `baseline_suffix` — a snapshot `<name>` has its baseline in
      `<baseline_dir>/**/<name><baseline_suffix>` (default `.png`).
    * `ignore_paths` — globs of repo files that never render a page (docs, tests,
      CI config). The branch's own changes to everything else, except the baselines,
      count as "may have changed the failing pages" and stop the auto-refresh.
    * `max_snapshots` — refuse to refresh more than this many snapshots at once
      (default 50): a wholesale mismatch is not routine drift.
  """

  alias Arbiter.Tasks.RepoConfig

  @enforce_keys [:job, :baseline_dir]
  defstruct [
    :job,
    :baseline_dir,
    :artifact,
    artifact_path: "",
    actual_suffix: "-actual.png",
    baseline_suffix: ".png",
    ignore_paths: [],
    max_snapshots: 50
  ]

  @type t :: %__MODULE__{
          job: String.t(),
          baseline_dir: String.t(),
          artifact: String.t() | nil,
          artifact_path: String.t(),
          actual_suffix: String.t(),
          baseline_suffix: String.t(),
          ignore_paths: [String.t()],
          max_snapshots: pos_integer()
        }

  @doc """
  The effective config for `repo` in `workspace`: `:none` when unset,
  `{:ok, config}`, or `{:error, message}` for a block that does not validate (a
  hand-edited row; the write path refuses it, see `Arbiter.Tasks.Workspace.Changes.ValidateConfig`).
  """
  @spec resolve(term(), String.t() | nil) :: {:ok, t()} | :none | {:error, String.t()}
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    case effective(worker, repo) do
      nil -> :none
      block -> validate(block)
    end
  end

  def resolve(_workspace, _repo), do: :none

  defp effective(worker, repo) do
    {repos, base} = Map.pop(worker, "repos")
    top = Map.get(base, "visual_baselines")

    per_repo =
      with true <- is_binary(repo) and repo != "" and is_map(repos),
           %{} = entry <- RepoConfig.find_entry(repos, repo) do
        Map.get(entry, "visual_baselines")
      else
        _ -> nil
      end

    case {top, per_repo} do
      {nil, nil} -> nil
      {%{} = a, %{} = b} -> Map.merge(a, b)
      {a, nil} -> a
      {_, b} -> b
    end
  end

  @doc "Validate a raw `visual_baselines` map into a `t:t/0`."
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(%{} = block) do
    with {:ok, job} <- required_string(block, "job"),
         {:ok, baseline_dir} <- relative_path(block, "baseline_dir", :required),
         {:ok, artifact_path} <- relative_path(block, "artifact_path", ""),
         {:ok, artifact} <- optional_string(block, "artifact"),
         {:ok, actual_suffix} <- suffix(block, "actual_suffix", "-actual.png"),
         {:ok, baseline_suffix} <- suffix(block, "baseline_suffix", ".png"),
         {:ok, ignore_paths} <- string_list(block, "ignore_paths"),
         {:ok, max_snapshots} <- positive(block, "max_snapshots", 50) do
      {:ok,
       %__MODULE__{
         job: job,
         baseline_dir: baseline_dir,
         artifact: artifact,
         artifact_path: artifact_path,
         actual_suffix: actual_suffix,
         baseline_suffix: baseline_suffix,
         ignore_paths: ignore_paths,
         max_snapshots: max_snapshots
       }}
    end
  end

  def validate(_), do: {:error, "visual_baselines must be a map"}

  defp required_string(block, key) do
    case Map.get(block, key) do
      s when is_binary(s) -> if String.trim(s) == "", do: missing(key), else: {:ok, s}
      _ -> missing(key)
    end
  end

  defp missing(key), do: {:error, "visual_baselines.#{key} must be a non-empty string"}

  defp optional_string(block, key) do
    case Map.get(block, key) do
      nil -> {:ok, nil}
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> missing(key)
    end
  end

  defp relative_path(block, key, default) do
    case {Map.get(block, key), default} do
      {nil, :required} -> missing(key)
      {nil, default} -> {:ok, default}
      {path, _} when is_binary(path) -> check_relative(key, path)
      _ -> missing(key)
    end
  end

  defp check_relative(key, path) do
    parts = Path.split(path)

    cond do
      String.trim(path) == "" ->
        missing(key)

      Path.type(path) != :relative ->
        {:error, "visual_baselines.#{key} must be repo-relative"}

      ".." in parts or ".git" in parts ->
        {:error, "visual_baselines.#{key} must stay in the repo"}

      true ->
        {:ok, path |> Path.split() |> Path.join()}
    end
  end

  defp suffix(block, key, default) do
    case Map.get(block, key) do
      nil -> {:ok, default}
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> missing(key)
    end
  end

  defp string_list(block, key) do
    case Map.get(block, key) do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: {:ok, list},
          else: {:error, "visual_baselines.#{key} must be a list of non-empty strings"}

      _ ->
        {:error, "visual_baselines.#{key} must be a list of non-empty strings"}
    end
  end

  defp positive(block, key, default) do
    case Map.get(block, key) do
      nil -> {:ok, default}
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, "visual_baselines.#{key} must be a positive integer"}
    end
  end
end
