defmodule Arbiter.Worker.ResearchGrant do
  @moduledoc """
  The `research_read` ticket permission (bd-6ircwr): read-only access to
  Arbiter's *own* data for a research run, so research about Arbiter's behaviour
  (runs, logs, usage, review rounds, transcripts) does not come back partial
  because the worker tier is refused those routes.

  It is a permission on the existing G12–G15 rails, not a new token tier:

    * **Declared** on a `task` / `research` ticket (`Arbiter.Guardrails.Permissions.check_issue_type/2`),
      by a coordinator or the operator. A worker never sets it, though it may ask
      for it (`permission_request`) like any other bound action.
    * **Off by default per workspace**: the workspace must bind it
      (`guardrails.bindings.research_read`, any map, optionally `grant_by`),
      exactly like `prod_read` needs its binding. No binding, nothing projected.
    * **Settled like every permission**: a `grant_by: operator` binding keeps it
      `requested` (pending) until the operator grants it; only the in-force
      permission counts.
    * **Never for a reviewer** (design §5.4).

  A granted run gets two things, and only for that run:

    1. a `research_read` claim in its worker token, which `ArbiterWeb.ApiPolicy`'s
       `:research_read` policy turns into `GET` access to the run, usage and
       review-round routes of **its own workspace** (the controllers confine a
       workspace-bound token; there is no mutating route on that policy);
    2. a read-only snapshot of its workspace's transcript archive
       (`stage_transcripts/3`), bind-mounted read-only by the podman backend.

  The snapshot is a **copy**, not a link or a bind of the archive root: the
  archive is keyed by run id with no workspace in the path, so mounting the root
  would expose every other workspace's transcripts, and a hard link would let a
  write through the snapshot reach the original. Copies are `0444`.

  The grant is audited as a `granted` `permission_events` row per dispatch
  (`audit/3`), on top of the `declared`/`requested`/`granted` rows the ticket
  already carries; each request a granted token makes is logged by
  `ArbiterWeb.Plugs.ApiAuth`.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run

  @permission "research_read"
  @default_limit 200
  @scan_cap 5_000
  @index "index.tsv"

  @type decision :: %{
          granted?: boolean(),
          claims: [String.t()],
          withheld: String.t() | nil
        }

  @doc "The permission name (and the token claim it becomes)."
  @spec permission() :: String.t()
  def permission, do: @permission

  @doc """
  Whether `issue`, run as `role` in `workspace`, is given `research_read`.

  `withheld` is `nil` when the ticket never asked for it, and the reason
  (recorded on the run, shown in the prompt) when it asked and did not get it.
  """
  @spec resolve(Issue.t(), map() | nil, :implementer | :reviewer) :: decision()
  def resolve(%Issue{} = issue, workspace, role) do
    declared? = @permission in (issue.permissions || [])

    cond do
      not declared? ->
        none(nil)

      role != :implementer ->
        none("reviewers get no action permissions")

      @permission in Permissions.pending(issue) ->
        none("pending: awaiting the grant its workspace binding requires")

      not bound?(workspace) ->
        none(
          "this workspace has no guardrails.bindings.research_read, so research access is off " <>
            "(it is opt-in per workspace)"
        )

      issue.issue_type not in [:task, :research] ->
        none("research_read is only for task and research tickets, not #{issue.issue_type}")

      true ->
        %{granted?: true, claims: [@permission], withheld: nil}
    end
  end

  defp none(reason), do: %{granted?: false, claims: [], withheld: reason}

  defp bound?(workspace) do
    block = Config.block(workspace)
    parsed = %{kind: :research_read, optional?: false, canonical: @permission}
    not is_nil(Vocabulary.binding(block, parsed))
  end

  @doc """
  Copy the transcripts of `workspace_id`'s most recent runs into `dest` (created),
  read-only, with an `index.tsv` mapping run id to task. Returns the directory
  and how many transcripts it holds.

  Options: `:root` (the archive, default `Arbiter.Worker.OutputLog.root/0`) and
  `:limit` (default #{@default_limit}). A run with no transcript on disk is
  skipped and does not count against the limit; an absent archive stages an empty
  snapshot.
  """
  @spec stage_transcripts(String.t(), Path.t(), keyword()) ::
          {:ok, %{dir: Path.t(), count: non_neg_integer()}} | {:error, term()}
  def stage_transcripts(workspace_id, dest, opts \\ [])
      when is_binary(workspace_id) and is_binary(dest) do
    root = Keyword.get_lazy(opts, :root, &OutputLog.root/0)
    limit = Keyword.get(opts, :limit, @default_limit)

    with :ok <- File.mkdir_p(dest) do
      staged =
        workspace_id
        |> recent_runs()
        |> Stream.map(&{&1, Path.join(root, &1.id <> ".log")})
        |> Stream.filter(fn {_run, src} -> File.regular?(src) end)
        |> Stream.map(fn {run, src} -> stage(run, src, dest) end)
        |> Stream.reject(&is_nil/1)
        |> Enum.take(limit)

      write_index(dest, staged)
      {:ok, %{dir: dest, count: length(staged)}}
    end
  end

  defp recent_runs(workspace_id) do
    Run
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(@scan_cap)
    |> Ash.Query.select([:id, :task_id, :kind, :started_at])
    |> Ash.read!()
  end

  defp stage(run, src, dest) do
    target = Path.join(dest, run.id <> ".log")

    with :ok <- File.cp(src, target),
         :ok <- File.chmod(target, 0o444) do
      run
    else
      {:error, reason} ->
        Logger.warning("ResearchGrant: could not stage #{src}: #{inspect(reason)}")
        nil
    end
  end

  defp write_index(dest, runs) do
    rows =
      Enum.map(runs, fn r ->
        Enum.join(
          [r.id, r.task_id, r.kind, r.started_at && DateTime.to_iso8601(r.started_at)],
          "\t"
        )
      end)

    path = Path.join(dest, @index)
    File.write!(path, Enum.join(["run_id\ttask_id\tkind\tstarted_at" | rows], "\n") <> "\n")
    File.chmod!(path, 0o444)
  end

  @doc """
  Audit the grant: one `granted` `permission_events` row (source `system`) saying
  the run was given research access and what it was given. Append-only, like every
  permission event. `opts`: `:transcripts` (the snapshot size).
  """
  @spec audit(Issue.t(), String.t() | nil, keyword()) :: :ok | :error
  def audit(%Issue{id: id}, run_id, opts \\ []) do
    snapshot =
      case Keyword.get(opts, :transcripts) do
        nil -> "a read-only snapshot of its workspace's transcripts (podman backend)"
        count -> "a read-only snapshot of #{count} transcripts"
      end

    Permissions.record!(
      [%{permission: @permission, event: :granted}],
      id,
      :system,
      actor: "dispatch",
      run_id: run_id,
      reason:
        "research access projected into the run: read-only run/usage/review-round routes of " <>
          "its workspace, and #{snapshot}"
    )
  rescue
    error ->
      Logger.warning("ResearchGrant: audit row not recorded: #{Exception.message(error)}")
      :error
  end
end
