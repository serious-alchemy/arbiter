defmodule Arbiter.Workflows.DeployWatch do
  @moduledoc """
  Watches the post-merge deploy on deploy-on-merge repos (#967).

  Arbiter's responsibility used to end at merge. On a repo whose main pipeline
  deploys (tonic, vstim) a broken CD was invisible: on 2026-10-18 three main
  pipelines reported SUCCESS while `build` and `deploy` were SKIPPED, and
  nothing noticed for 2.5h.

  ## Config

  Off unless the repo sets `merge.repos.<repo>.deploy_watch`:

      "deploy_watch": {"job": "deploy", "timeout_minutes": 90}
      "deploy_watch": {"jobs": ["deploy-web", "deploy-worker"]}

  `job` (one name) or `jobs` (all must succeed); `timeout_minutes` defaults to
  90. The base branch is the repo's `merge.base` (default `main`).

  ## How it runs

  `sweep/3` is called by `MergedPRFinalizer` on every tick for its repo. It

    1. **registers** merged tickets of the repo (closed or `:verifying`, merged
       within the last 7 days) that carry no `deploy_watch` record yet, reading
       the merge commit off the forge (`adapter.get/1` → `:merge_sha`). Both merge
       paths (the merge queue and the finalizer) close a ticket the same way, so
       neither needs a hook. The record lives in the ticket's `merger_status`
       under `"deploy_watch"`.
    2. **evaluates** every unresolved watch against the base branch's newest
       pipelines (`adapter.deploy_pipelines/3`): the merge commit's own pipeline
       or any later pipeline whose commit contains it (`adapter.ancestor?/3`).
       A pipeline where every watched job is `success` resolves the watch as
       `deployed` (`deployed_at`, `pipeline_id` recorded, no alert). Supersession
       is not an alert: a canceled pipeline, or one whose deploy job did not run,
       waits for a later pipeline that contains the commit.
    3. **alerts** when the commit's own pipeline settled without the watched
       job(s) succeeding and no later pipeline is still in flight, or when
       nothing has deployed it within the timeout. The alert is a
       coordinator-owned `:deploy_failing` system alert keyed by workspace and
       repo, so merges during one outage fold into a single alert (naming every
       affected merge). It clears whenever no watch of the repo is alerted any more (all deployed,
       aged out, or `deploy_watch` removed).

  `repo` is the *ticket* repo key (`repo_paths` key): the finalizer maps its
  forge slug to keys via `MergedPRFinalizerSupervisor.repo_keys/2` and sweeps
  each. `nil` (no `repo_paths`) covers every ticket in the workspace.
  """

  alias Arbiter.Alerts
  alias Arbiter.Mergers
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  require Ash.Query
  require Logger

  @default_timeout_minutes 90
  @retention_days 7

  @type config :: %{jobs: [String.t()], timeout_minutes: pos_integer(), branch: String.t()}
  @type verdict :: :pending | {:deployed, map()} | {:failed, map() | nil}

  # ---- config ---------------------------------------------------------------

  @doc """
  The effective deploy-watch config for `repo` in `workspace`, or `nil` when
  unset or invalid (off).
  """
  @spec config(Workspace.t() | nil, String.t() | nil) :: config() | nil
  def config(workspace, repo) when is_binary(repo) or is_nil(repo) do
    case Mergers.merge_config(workspace, repo) do
      %{"deploy_watch" => %{} = dw} -> build_config(dw, workspace, repo)
      _ -> nil
    end
  end

  def config(_workspace, _repo), do: nil

  defp build_config(dw, workspace, repo) do
    jobs =
      (List.wrap(dw["jobs"]) ++ List.wrap(dw["job"]))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    case jobs do
      [] ->
        nil

      jobs ->
        %{
          jobs: jobs,
          timeout_minutes: timeout_minutes(dw["timeout_minutes"]),
          branch: Mergers.base_branch(workspace, repo) || "main"
        }
    end
  end

  defp timeout_minutes(n) when is_integer(n) and n > 0, do: n
  defp timeout_minutes(_), do: @default_timeout_minutes

  # ---- pure evaluation ------------------------------------------------------

  @doc """
  Judge one watch against the base branch's pipelines (newest first).

  `watch` is the stored record (`"sha"`, `"merged_at"`). `ancestor?` is a
  2-arity `(ancestor_sha, descendant_sha) -> boolean` answering "does the
  descendant commit contain the ancestor". Returns `:pending`,
  `{:deployed, pipeline}` or `{:failed, pipeline | nil}` (the commit's own
  pipeline, else the newest containing one, else `nil` — nothing ever ran).
  """
  @spec evaluate(map(), [map()], (String.t(), String.t() -> boolean()), config(), DateTime.t()) ::
          verdict()
  def evaluate(%{"sha" => sha} = watch, pipelines, ancestor?, %{jobs: jobs} = cfg, now) do
    own = Enum.find(pipelines, &(&1.sha == sha))

    newer = pipelines_after(pipelines, own)
    contains? = fn p -> is_binary(p.sha) and ancestor?.(sha, p.sha) == true end
    unknown? = fn p -> is_binary(p.sha) and ancestor?.(sha, p.sha) == :unknown end

    case find_deployed(own, newer, jobs, contains?) do
      nil ->
        if timed_out?(watch, cfg, now),
          do: {:failed, own || Enum.find(newer, contains?)},
          else: undeployed_verdict(own, newer, contains?, unknown?, jobs)

      deployed ->
        {:deployed, deployed}
    end
  end

  defp pipelines_after(pipelines, nil), do: pipelines
  defp pipelines_after(pipelines, own), do: Enum.take_while(pipelines, &(&1.id != own.id))

  # Cheap local checks (job statuses, in-flight) gate every forge ancestry
  # call, and the search stops at the first hit.
  defp find_deployed(own, newer, jobs, contains?) do
    if(own && watched_ok?(own, jobs), do: own) ||
      Enum.find(newer, &(watched_ok?(&1, jobs) and contains?.(&1)))
  end

  # Not timed out and nothing succeeded yet.
  defp undeployed_verdict(own, newer, contains?, unknown?, jobs) do
    cond do
      # A later pipeline passed but the forge could not say whether it holds
      # our commit (lookup error): wait for the next sweep rather than alert.
      Enum.any?(newer, &(watched_ok?(&1, jobs) and unknown?.(&1))) -> :pending
      own && in_flight?(own) -> :pending
      Enum.any?(newer, &(in_flight?(&1) and contains?.(&1))) -> :pending
      # Auto-canceled by a newer merge: a successor will carry the commit.
      own && own.status == "canceled" -> :pending
      own -> {:failed, own}
      true -> :pending
    end
  end

  @doc "Each watched job's status in `pipeline` (`\"missing\"` when never created)."
  @spec job_statuses(map(), [String.t()]) :: %{String.t() => String.t()}
  def job_statuses(pipeline, jobs) do
    Map.new(jobs, fn name ->
      statuses = for j <- pipeline.jobs, j.name == name, do: j.status

      status =
        cond do
          "success" in statuses -> "success"
          statuses != [] -> hd(statuses)
          true -> "missing"
        end

      {name, status}
    end)
  end

  defp watched_ok?(pipeline, jobs),
    do: pipeline |> job_statuses(jobs) |> Map.values() |> Enum.all?(&(&1 == "success"))

  defp in_flight?(%{status: status}),
    do:
      status in [
        "running",
        "pending",
        "created",
        "waiting_for_resource",
        "preparing",
        "scheduled"
      ]

  defp timed_out?(watch, cfg, now) do
    case parse_time(watch["merged_at"]) do
      nil -> false
      merged_at -> DateTime.diff(now, merged_at, :minute) >= cfg.timeout_minutes
    end
  end

  # ---- the sweep ------------------------------------------------------------

  @doc """
  One sweep for `repo`: register, evaluate, alert/clear. A no-op (`:off`) when
  the repo has no `deploy_watch` or the adapter cannot list pipelines. Never
  raises. `opts[:now]` overrides the clock (tests).
  """
  @spec sweep(Workspace.t(), String.t() | nil, module(), keyword()) :: :off | :ok
  def sweep(%Workspace{} = workspace, repo, adapter, opts \\ []) do
    with %{} = cfg <- config(workspace, repo),
         true <- function_exported?(adapter, :deploy_pipelines, 3) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      do_sweep(workspace, repo, adapter, cfg, now)
      :ok
    else
      _ ->
        # Watch removed from config: don't leave its alert open.
        _ = Alerts.clear(:deploy_failing, alert_key(workspace.id, repo))
        :off
    end
  rescue
    e ->
      Logger.warning("DeployWatch: sweep for #{repo} raised: #{Exception.message(e)}")
      :ok
  end

  defp do_sweep(workspace, repo, adapter, cfg, now) do
    tasks = candidate_tasks(workspace.id, repo, now)

    tasks =
      tasks
      |> Enum.map(&register(&1, adapter, now))
      |> Enum.reject(&is_nil/1)

    unresolved = Enum.filter(tasks, &(watch(&1)["state"] in ["pending", "alerted"]))

    if unresolved == [] do
      # Nothing left to watch (including alerted tickets aged out of the
      # window): the outage alert must not outlive its watches.
      _ = Alerts.clear(:deploy_failing, alert_key(workspace.id, repo))
      :ok
    else
      evaluate_all(workspace, repo, adapter, cfg, unresolved, now)
    end
  end

  defp candidate_tasks(workspace_id, repo, now) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    Issue
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and state in [:closed, :verifying] and not is_nil(pr_ref)
    )
    |> filter_repo(repo)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(200)
    |> Ash.read!()
    |> Enum.filter(&merged_recently?(&1, cutoff))
    |> Enum.sort_by(&merged_at(&1), DateTime)
  end

  # `nil`: a workspace without `repo_paths` — every ticket is the one repo's.
  defp filter_repo(query, nil), do: query
  defp filter_repo(query, repo), do: Ash.Query.filter(query, repo == ^repo)

  defp merged_recently?(%Issue{merger_status: %{"status" => "merged"}} = task, cutoff),
    do: DateTime.compare(merged_at(task), cutoff) != :lt

  defp merged_recently?(_task, _cutoff), do: false

  defp merged_at(%Issue{} = task), do: task.closed_at || task.updated_at || task.created_at

  defp watch(%Issue{merger_status: ms}), do: (ms || %{})["deploy_watch"] || %{}

  # A task that already has a record is returned as is; one without gets its
  # merge commit read off the forge and a `pending` record written. `nil` when
  # the forge cannot say (yet): the next tick tries again.
  defp register(%Issue{} = task, adapter, _now) do
    case watch(task) do
      w when map_size(w) > 0 ->
        task

      _ ->
        case adapter.get(task.pr_ref) do
          {:ok, %{status: :merged, merge_sha: sha}} when is_binary(sha) and sha != "" ->
            record(task, %{
              "state" => "pending",
              "sha" => sha,
              "merged_at" => DateTime.to_iso8601(merged_at(task))
            })

          _ ->
            nil
        end
    end
  end

  defp evaluate_all(workspace, repo, adapter, cfg, tasks, now) do
    # Any task's pr_ref locates the project on the adapter.
    mr_ref = hd(tasks).pr_ref

    case adapter.deploy_pipelines(mr_ref, cfg.branch, %{jobs: cfg.jobs}) do
      {:ok, pipelines} ->
        ancestor? = ancestor_fun(adapter, mr_ref)

        results =
          Enum.map(tasks, fn task ->
            {task, evaluate(watch(task), pipelines, ancestor?, cfg, now)}
          end)

        apply_results(workspace, repo, cfg, results, now)

      {:error, reason} ->
        Logger.warning(
          "DeployWatch: cannot list #{cfg.branch} pipelines for #{repo}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ancestor_fun(adapter, mr_ref) do
    if function_exported?(adapter, :ancestor?, 3) do
      fn ancestor, descendant ->
        case adapter.ancestor?(mr_ref, ancestor, descendant) do
          {:ok, answer} when is_boolean(answer) -> answer
          _ -> :unknown
        end
      end
    else
      fn ancestor, descendant -> ancestor == descendant end
    end
  end

  defp apply_results(workspace, repo, cfg, results, now) do
    updated =
      Enum.map(results, fn {task, verdict} ->
        {apply_verdict(task, verdict, cfg, now), verdict}
      end)

    alerted =
      for {task, _} <- updated, watch(task)["state"] == "alerted", do: task

    key = alert_key(workspace.id, repo)

    cond do
      alerted != [] and Enum.any?(updated, &new_failure?/1) ->
        raise_alert(workspace.id, repo, key, cfg, alerted)

      alerted == [] ->
        _ = Alerts.clear(:deploy_failing, key)
        :ok

      true ->
        :ok
    end
  end

  defp new_failure?({task, {:failed, _}}), do: watch(task)["fresh_alert"] == true
  defp new_failure?(_), do: false

  defp apply_verdict(task, :pending, _cfg, _now), do: task

  defp apply_verdict(task, {:deployed, pipeline}, cfg, now) do
    record(task, %{
      "state" => "deployed",
      "deployed_at" => DateTime.to_iso8601(now),
      "pipeline_id" => pipeline.id,
      "pipeline_url" => pipeline.url,
      "pipeline_sha" => pipeline.sha,
      "job_statuses" => job_statuses(pipeline, cfg.jobs)
    })
  end

  defp apply_verdict(task, {:failed, pipeline}, cfg, now) do
    case watch(task) do
      %{"state" => "alerted"} ->
        task

      _ ->
        task
        |> record(%{
          "state" => "alerted",
          "alerted_at" => DateTime.to_iso8601(now),
          "pipeline_id" => pipeline && pipeline.id,
          "pipeline_url" => pipeline && pipeline.url,
          "job_statuses" => if(pipeline, do: job_statuses(pipeline, cfg.jobs), else: %{})
        })
        |> mark_fresh()
    end
  end

  # In-memory only (never persisted): lets `apply_results/5` tell a failure
  # found this sweep from one already alerted.
  defp mark_fresh(%Issue{merger_status: ms} = task) do
    dw = Map.put(ms["deploy_watch"], "fresh_alert", true)
    %{task | merger_status: Map.put(ms, "deploy_watch", dw)}
  end

  defp record(%Issue{} = task, changes) do
    ms = task.merger_status || %{}
    dw = Map.merge(ms["deploy_watch"] || %{}, changes)

    case Ash.update(task, %{merger_status: Map.put(ms, "deploy_watch", dw)},
           action: :record_merger_status
         ) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning("DeployWatch: could not record on task=#{task.id}: #{inspect(reason)}")
        task
    end
  end

  # ---- alert ----------------------------------------------------------------

  @doc "The system-alert key for `repo`'s deploy outage."
  @spec alert_key(String.t(), String.t() | nil) :: String.t()
  def alert_key(workspace_id, repo), do: "#{workspace_id}:#{repo || "default"}"

  defp raise_alert(workspace_id, repo, key, cfg, alerted) do
    lines = Enum.map(alerted, &alert_line(&1, cfg))

    detail =
      "The post-merge deploy on #{repo} (#{cfg.branch}) did not run the watched job(s) " <>
        "#{Enum.join(cfg.jobs, ", ")} to success for #{length(alerted)} merge(s):\n" <>
        Enum.join(lines, "\n")

    case Alerts.raise_alert(%{
           kind: :deploy_failing,
           key: key,
           workspace_id: workspace_id,
           subject: "#{repo}: post-merge deploy not succeeding",
           detail: detail,
           owner: :coordinator
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("DeployWatch: could not raise alert: #{inspect(reason)}")
    end
  end

  defp alert_line(task, cfg) do
    w = watch(task)

    statuses =
      case w["job_statuses"] do
        %{} = s when map_size(s) > 0 -> Enum.map_join(s, ", ", fn {k, v} -> "#{k}=#{v}" end)
        _ -> "no pipeline found for the commit within #{cfg.timeout_minutes}m"
      end

    "- #{task.id} merge #{w["sha"]}: pipeline #{w["pipeline_id"] || "none"} " <>
      "#{w["pipeline_url"] || ""} — #{statuses}"
  end

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
