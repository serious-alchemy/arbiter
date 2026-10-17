defmodule Arbiter.Worker.VisualBaselines do
  @moduledoc """
  The deterministic visual-baseline refresh (bd-9obzu9, GitHub #936).

  Several UI branches change the same pages, so every merge to main makes the
  other open branches' reference screenshots stale and their `visual` job fails.
  Fixing that is mechanical: download the job's actual images and copy them over
  the baselines. This module does it without an agent, for exactly the case where
  that is safe, and never otherwise.

  `refresh/1` runs when a head's CI is red (the Watchdog's `:ci_failed` path calls
  it before dispatching a fix pass) and the repo has a
  `worker.repos.<repo>.visual_baselines` block (`Config`). It refreshes only when

    1. the configured visual job is the **only** failed job of the head's pipeline
       and the artifacts belong to that exact head (`ci_job_artifacts/3`);
    2. the failure is main's drift, not the branch's own work (`Drift.decide/5`,
       against the last commit whose visual job was green, `last_green_job_sha/3`);
    3. every actual image maps to exactly one existing baseline (`Archive.plan/3`).

  Then, in a throwaway checkout of the branch (never the shared one), it overwrites
  those baseline files only, commits "Refresh visual baselines after syncing main (auto)"
  and pushes a plain, non-forced push with the repo's host credential. Anything
  else returns `{:skip, reason}` and the failure takes the normal fix path.

  The push is an authored push like a CI fix pass's: the caller records it as one
  (`Watchdog.note_authored_push/1`), so the new head — with its image diff — goes
  back through the ReviewGate before the PR can merge.

  The adapter supplies two optional `Arbiter.Mergers.Merger` callbacks,
  `ci_job_artifacts/3` and `last_green_job_sha/3`.
  """

  require Logger

  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Worker.HostCredential
  alias Arbiter.Worker.VisualBaselines.{Archive, Config, Drift}

  @type ctx :: %{
          required(:workspace) => term(),
          required(:repo) => String.t() | nil,
          required(:adapter) => module(),
          required(:mr_ref) => String.t(),
          required(:result) => map()
        }

  @type outcome ::
          {:refreshed, %{sha: String.t(), files: [String.t()]}}
          | {:skip, term()}
          | {:error, term()}

  @doc "The subject of the commit this makes."
  @spec commit_subject() :: String.t()
  def commit_subject, do: Drift.refresh_subject()

  @doc "Whether `repo` has a (valid) `visual_baselines` block: the cheap test the callers gate on."
  @spec configured?(term(), String.t() | nil) :: boolean()
  def configured?(workspace, repo), do: match?({:ok, _}, Config.resolve(workspace, repo))

  @spec refresh(ctx()) :: outcome()
  def refresh(%{workspace: workspace, repo: repo} = ctx) do
    case Config.resolve(workspace, repo) do
      {:ok, config} ->
        run(ctx, config)

      :none ->
        {:skip, :not_configured}

      {:error, message} ->
        Logger.warning("VisualBaselines: #{repo}: #{message}; not refreshing")
        {:skip, {:invalid_config, message}}
    end
  rescue
    e ->
      Logger.warning("VisualBaselines: refresh raised #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp run(ctx, config) do
    %{adapter: adapter, mr_ref: mr_ref, result: result} = ctx
    head = Map.get(result, :head_sha)
    branch = Map.get(result, :head_ref)
    target = Map.get(result, :base_ref)

    with :ok <- supported(adapter),
         :ok <- present([head, branch, target]),
         {:ok, artifacts} <- artifacts(adapter, mr_ref, config, head),
         {:ok, green} <- green_run(adapter, mr_ref, config),
         {:ok, repo_path} <- repo_path(ctx) do
      in_checkout(repo_path, branch, head, fn path ->
        with {:ok, target_sha} <- fetch_target(path, target),
             :ok <- verdict(Drift.decide(path, target_sha, head, green, config)),
             {:ok, plan} <- plan(artifacts.archive, config, path) do
          apply_and_push(ctx, path, branch, plan)
        end
      end)
    end
  end

  defp supported(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :ci_job_artifacts, 3) and
         function_exported?(adapter, :last_green_job_sha, 3),
       do: :ok,
       else: {:skip, :adapter_unsupported}
  end

  defp present(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:skip, :head_unknown}
  end

  defp artifacts(adapter, mr_ref, config, head) do
    case adapter.ci_job_artifacts(mr_ref, config.job, %{artifact: config.artifact}) do
      {:ok, %{sha: sha, failed_jobs: failed, archive: archive}} when is_binary(archive) ->
        cond do
          sha != head -> {:skip, :artifacts_for_another_head}
          failed -- [config.job] != [] -> {:skip, {:other_jobs_failed, failed -- [config.job]}}
          config.job not in failed -> {:skip, :visual_job_not_failed}
          true -> {:ok, %{archive: archive}}
        end

      {:ok, _} ->
        {:skip, :no_artifacts}

      {:error, reason} ->
        {:skip, {:artifacts_unreadable, reason}}
    end
  end

  defp green_run(adapter, mr_ref, config) do
    case adapter.last_green_job_sha(mr_ref, config.job, %{}) do
      {:ok, sha} when is_binary(sha) or is_nil(sha) -> {:ok, sha}
      {:error, reason} -> {:skip, {:green_run_unreadable, reason}}
      _ -> {:skip, {:green_run_unreadable, :bad_reply}}
    end
  end

  defp repo_path(%{workspace: workspace, repo: repo}) do
    case LocalCompare.repo_path(workspace, repo) do
      path when is_binary(path) -> {:ok, path}
      _ -> {:skip, :no_local_repo}
    end
  end

  # A throwaway detached checkout at the branch's origin tip. If origin has moved
  # past the head the pipeline ran on, the artifacts describe a commit that is no
  # longer the branch: refuse.
  defp in_checkout(repo_path, branch, head, fun) do
    case Checkout.provision_branch(repo_path, branch, prefix: "visual-baselines") do
      {:ok, %{path: path, head_sha: tip}} ->
        try do
          if tip == head, do: fun.(path), else: {:skip, :branch_moved}
        after
          Checkout.teardown(path)
        end

      {:error, reason} ->
        {:skip, {:no_checkout, reason}}
    end
  end

  defp fetch_target(path, target) do
    ref = "refs/arbiter/visual/target-#{System.unique_integer([:positive])}"

    with {:ok, _} <- Drift.git(path, ["fetch", "--no-tags", "origin", "+#{target}:#{ref}"]),
         {:ok, sha} <- Drift.git(path, ["rev-parse", ref <> "^{commit}"]) do
      _ = Drift.git(path, ["update-ref", "-d", ref])
      {:ok, sha}
    else
      _ -> {:skip, :target_unavailable}
    end
  end

  defp verdict(:ok), do: :ok
  defp verdict({:skip, reason}), do: {:skip, reason}

  defp plan(archive, config, path) do
    case Archive.plan(archive, config, path) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp apply_and_push(ctx, path, branch, plan) do
    files = plan |> Enum.map(& &1.baseline) |> Enum.sort()

    with :ok <- write_files(path, plan),
         {:ok, _} <- Drift.git(path, ["add", "--" | files]),
         :ok <- only_staged(path, files),
         {:ok, sha} <- commit(path, plan),
         {:ok, credential} <- credential(ctx, path),
         :ok <- push(path, branch, credential) do
      Logger.info(
        "VisualBaselines: refreshed #{length(files)} baseline(s) on #{branch} for " <>
          "#{ctx.mr_ref} (#{sha})"
      )

      {:refreshed, %{sha: sha, files: files}}
    else
      {:error, _} = error -> error
    end
  end

  defp write_files(path, plan) do
    Enum.reduce_while(plan, :ok, fn %{baseline: rel, bytes: bytes}, :ok ->
      case File.write(Path.join(path, rel), bytes) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_failed, rel, reason}}}
      end
    end)
  end

  # The plan is the whole change: if git stages anything else, stop.
  defp only_staged(path, files) do
    case Drift.git(path, ["diff", "--cached", "--name-only", "-z"]) do
      {:ok, out} ->
        staged = out |> String.split(<<0>>, trim: true) |> Enum.sort()
        if staged == files, do: :ok, else: {:error, {:unexpected_staged, staged}}

      {:error, reason} ->
        {:error, {:git, reason}}
    end
  end

  defp commit(path, plan) do
    body =
      "Replaced from the visual job's actual images:\n" <>
        Enum.map_join(plan, "\n", &"- #{&1.baseline}")

    args = [
      "-c",
      "user.name=Arbiter",
      "-c",
      "user.email=arbiter@localhost",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "--no-verify",
      "-m",
      commit_subject(),
      "-m",
      body
    ]

    with {:ok, _} <- Drift.git(path, args),
         {:ok, sha} <- Drift.git(path, ["rev-parse", "HEAD"]) do
      {:ok, sha}
    else
      {:error, reason} -> {:error, {:commit_failed, reason}}
    end
  end

  defp credential(%{workspace: workspace, repo: repo}, path) do
    case HostCredential.for_repo(workspace, repo, worktree_path: path) do
      {:ok, credential} -> {:ok, credential}
      {:error, reason} -> {:error, {:credential, HostCredential.format_error(reason)}}
    end
  end

  # Plain push, never forced: a branch that moved since the checkout was cut
  # rejects it and nothing is overwritten.
  defp push(path, branch, credential) do
    env = HostCredential.push_env(credential)

    case System.cmd("git", ["-C", path, "push", "origin", "HEAD:refs/heads/" <> branch],
           stderr_to_stdout: true,
           env: env
         ) do
      {_, 0} -> :ok
      {out, _} -> {:error, {:push_failed, String.trim(out)}}
    end
  end
end
