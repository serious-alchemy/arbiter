defmodule Arbiter.Reviews.Guard do
  @moduledoc """
  The one `review_automation` guard for a **task-shaped review** (`worker_review`
  / `POST /api/workers/review` / `arb worker review`, bd-dtfe9x).

  The guard used to live in the MCP tool alone and read the *caller's* bound
  workspace (`scope.workspace_id`). A normal coordinator token is
  workspace-agnostic (`workspace_id: nil`), so that read came back empty: the
  `off` / `repo_overrides` refusals never fired, and `:flag` was persisted onto
  the engagement, silently downgrading a workspace that would have resolved to
  `:auto`. REST and the CLI had no guard at all. Now every surface calls
  `prepare/3`, which resolves the config from the **task's** workspace
  (`task.workspace_id`) — the only workspace the review can act on.

  `params` is the string-keyed arg/param map every surface already holds:
  `"repo"`, `"pr_author"`, `"automation"`, `"tracker_context_ref"`,
  `"tracker_context_type"`.

  Resolution order (most specific wins — see `Arbiter.Worker.ReviewAutomation`):
  an explicit `automation` arg, then `repo_overrides[repo]`, then `auto_authors`
  / `default`. A mode of `:off` refuses the dispatch unless `force` is set.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Worker.ReviewAutomation

  require Logger

  @type decision :: %{
          mode: ReviewAutomation.mode(),
          source: ReviewAutomation.source(),
          persist?: boolean()
        }

  @doc """
  Resolve the automation mode for `task` and refuse when it is `:off` (unless
  `force`). Touches nothing.

  `persist?` is true only when something actually configured the mode — an
  explicit `automation` arg, a `repo_overrides` entry, or a `review_automation`
  block on the task's workspace. With no config at all the mode is the
  conservative `:flag` fallback, which must not be written onto the engagement.
  """
  @spec check(Issue.t(), map(), boolean()) ::
          {:ok, decision()} | {:error, {:invalid, String.t()}}
  def check(%Issue{} = task, params, force) when is_map(params) do
    config = workspace_config(task.workspace_id)
    repo_name = string(params, "repo")
    explicit = string(params, "automation")

    {mode, source} =
      ReviewAutomation.resolve_with_source(config, string(params, "pr_author"), repo_name, explicit)

    Logger.info(
      "worker_review(#{task.id}): resolved review_automation=#{mode} (source: #{source})" <>
        if(repo_name, do: " [#{repo_name}]", else: "")
    )

    if mode == :off and force != true do
      {:error, {:invalid, off_message(repo_name, source)}}
    else
      {:ok, %{mode: mode, source: source, persist?: persist?(config, source)}}
    end
  end

  @doc """
  The full pre-dispatch step every surface runs: `check/3`, then persist the
  resolved mode on the engagement (when something configured it) and the
  optional `tracker_context_*` params. Returns the updated task. A refusal
  leaves the task untouched.
  """
  @spec prepare(Issue.t(), map(), boolean()) ::
          {:ok, Issue.t()} | {:error, {:invalid, String.t()}}
  def prepare(%Issue{} = task, params, force) when is_map(params) do
    with {:ok, decision} <- check(task, params, force),
         {:ok, task} <- persist_mode(task, decision) do
      set_tracker_context(task, params)
    end
  end

  # ---- persistence -------------------------------------------------------

  defp persist_mode(task, %{persist?: false}), do: {:ok, task}

  defp persist_mode(task, %{mode: mode}) do
    case Ash.update(task, %{review_automation: mode}) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, {:invalid, Exception.message(err)}}
    end
  end

  # If `tracker_context_ref` is provided, persist it (and optionally
  # `tracker_context_type`) on the task before dispatch so the review prompt
  # can fetch the ticket's acceptance criteria. When the type is omitted, the
  # workspace's default tracker type is the fallback — the common case
  # (reviewee and reviewer share a tracker).
  defp set_tracker_context(task, params) do
    case string(params, "tracker_context_ref") do
      nil ->
        {:ok, task}

      ref ->
        attrs =
          %{"tracker_context_ref" => ref}
          |> put_context_type(context_type(task, string(params, "tracker_context_type")))

        case Ash.update(task, attrs, action: :update) do
          {:ok, updated} -> {:ok, updated}
          {:error, err} -> {:error, {:invalid, Exception.message(err)}}
        end
    end
  end

  defp put_context_type(attrs, nil), do: attrs
  defp put_context_type(attrs, type), do: Map.put(attrs, "tracker_context_type", type)

  defp context_type(task, nil) do
    case task.workspace_id && Ash.get(Workspace, task.workspace_id) do
      {:ok, %Workspace{} = ws} -> Trackers.workspace_type(ws)
      _ -> nil
    end
  end

  defp context_type(_task, type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> nil
  end

  # ---- helpers -----------------------------------------------------------

  defp persist?(_config, source) when source in [:explicit, :repo_override], do: true

  defp persist?(config, :default),
    do: is_map(config) and is_map(Map.get(config, "review_automation"))

  defp workspace_config(nil), do: nil

  defp workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: config}} -> config
      _ -> nil
    end
  end

  defp string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp off_message(repo_name, :repo_override) when is_binary(repo_name) do
    "review_automation is \"off\" for #{repo_name} " <>
      "(review_automation.repo_overrides[#{inspect(repo_name)}]); refusing to dispatch a " <>
      "reviewer — pass force: true to override"
  end

  defp off_message(repo_name, :explicit) do
    "review_automation was explicitly set to \"off\" for #{repo_name || "this task"} " <>
      "(the automation argument); refusing to dispatch a reviewer — pass force: true to override"
  end

  defp off_message(repo_name, _source) when is_binary(repo_name) do
    "review_automation is \"off\" by default for #{repo_name} (review_automation.default); " <>
      "refusing to dispatch a reviewer — pass force: true to override"
  end

  defp off_message(_repo_name, _source) do
    "review_automation is \"off\" by default for this workspace (review_automation.default); " <>
      "refusing to dispatch a reviewer — pass force: true to override"
  end
end
