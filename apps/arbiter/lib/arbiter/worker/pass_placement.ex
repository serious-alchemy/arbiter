defmodule Arbiter.Worker.PassPlacement do
  @moduledoc """
  Where a pass that writes commits runs, and what the node is seeded with
  (bd-bg87oz, `docs/design/remote-workers.md` §13): a ReviewGate **fix round**
  (`:review_fix_round`), a merge-queue **CI fix pass** (`:fix_pass`) and a
  **conflict pass** (`:conflict_pass`). `Arbiter.Nodes.Placement.eligible/1`
  admits all three when the run is podman + Claude on a private clone and the
  workspace's `worker.placement` is not `local_only`.

  ## Placement

  `place/2` is the second admission gate the dispatchers share
  (`Arbiter.Nodes.LocalCapacity.gate/2`): `{:ok, {:node, row}}` reserves a slot
  on `row` for the calling process (release it with `release/1` once the pass's
  worker is registered), `{:ok, :local}` runs on the primary, and
  `{:error, {:no_node_capacity, info}}` holds the pass: held, never failed, and no
  attempt spent. With `worker.placement` unset and the primary's cap not
  overridden nothing is decided and nothing is read.

  `probe/3` is the cheap early form `Arbiter.Workflows.MergeQueue.PassAdmission`
  asks before it takes the ticket's slot: could a node take this pass? It does not
  know the provider yet, so it only answers whether the primary's own cap is the
  gate (`:local`) or whether placement will decide (`:node_possible`), and holds a
  `remote_only` pass while no node has room.

  ## Seeding

  A node is seeded from the **home clone** (the pass's private clone on the
  primary), whose branch and `origin/<target>` can both be stale: the clone was
  cut from the main repo's refs, which were last fetched whenever, and a pass
  runs after someone else (a fix round, a patrol, a human) may have pushed. A
  shadow clone seeded from those would rebase onto an old target (the conflict
  pass that pushes a branch that still conflicts, bd-cccm1k) and build on a
  branch the forge has moved past (the diverged push, bd-4axlg0).

  `seed/3` refreshes the home clone from the forge first: `origin/<branch>` and
  `origin/<target>` are fetched, and the local branch is fast-forwarded to the
  forge head. It returns the **forge head observed** (`remote_head`), which the
  host push pins its `--force-with-lease` to: a third-party push after this point
  makes the lease refuse. A clone that has commits the forge lacks keeps them
  (`alignment: :ahead`); one that diverged from the forge is refused, because
  neither side can be dropped (`{:seed_diverged, local, remote}`), and the pass
  stays on the primary.

  A pass whose home clone holds uncommitted work is never placed
  (`Placement`'s `:local_work`): the seed carries commits, not the work tree.
  """

  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Placement
  alias Arbiter.Nodes.Refusal
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.StopReason
  alias Arbiter.Worker.Worktree

  require Logger

  @type kind :: :fix_pass | :conflict_pass | :review_fix_round | :reviewer
  @type seed :: %{
          remote_head: String.t(),
          target_tip: String.t(),
          alignment: :equal | :fast_forwarded | :ahead
        }

  @doc """
  Place a pass. `attrs`: `:task_id`, `:kind`, `:provider`, `:layout`
  (`GitLayout`), `:workspace` (a struct or nil) and optionally `:workspace_id`,
  `:clone_path` (the home clone the pass would run in: read for uncommitted work
  only once placement is actually in play). `opts[:placement_opts]` is the seam over
  `Placement.place/2` (`:nodes`, `:remote_available?`).
  """
  @spec place(map(), keyword()) ::
          {:ok, :local} | {:ok, {:node, map()}} | {:error, {:no_node_capacity, map()}}
  def place(%{kind: kind, task_id: task_id} = attrs, opts \\ []) do
    workspace = Map.get(attrs, :workspace)
    mode = Placement.mode(workspace)

    if mode == :local_only and not LocalCapacity.cap().enforced? do
      {:ok, :local}
    else
      request = %{
        task_id: task_id,
        workspace_id: workspace_id(workspace, attrs),
        kind: kind,
        provider: Map.get(attrs, :provider),
        layout: Map.get(attrs, :layout),
        no_pr?: false,
        local_work?: local_work?(Map.get(attrs, :clone_path)),
        mode: mode
      }

      LocalCapacity.gate(request, Keyword.get(opts, :placement_opts, []))
    end
  rescue
    e ->
      Logger.warning(
        "PassPlacement: placement crashed for #{attrs.task_id}: #{Exception.message(e)}"
      )

      {:ok, :local}
  end

  defp workspace_id(%{id: id}, _attrs) when is_binary(id), do: id
  defp workspace_id(_workspace, attrs), do: Map.get(attrs, :workspace_id)

  @doc "Give back the slot `place/2` reserved for `task_id` on a node."
  @spec release(String.t()) :: :ok
  def release(task_id), do: LocalCapacity.release(task_id)

  @doc """
  Would a node possibly take a `kind` pass of `task`? `:local` when the pass can only
  run on the primary (so its own cap is the gate), `:node_possible` when
  placement will decide once the provider is known, or the hold when
  `worker.placement` is `remote_only` and no node has room.

  The probe reserves nothing: a slot it takes is given straight back.
  """
  @spec probe(map(), kind(), keyword()) ::
          :local | :node_possible | {:error, {:no_node_capacity, map()}}
  def probe(task, kind, opts \\ []) do
    workspace = load_workspace(task.workspace_id)

    case Placement.mode(workspace) do
      :local_only ->
        :local

      mode ->
        probe_nodes(task, workspace, mode, kind, opts)
    end
  rescue
    _ -> :local
  end

  defp probe_nodes(task, workspace, mode, kind, opts) do
    request = %{
      task_id: task.id,
      workspace_id: task.workspace_id,
      kind: kind,
      provider: "claude",
      layout: :private_clone,
      no_pr?: false,
      mode: mode
    }

    _ = workspace

    case Placement.place(request, Keyword.get(opts, :placement_opts, [])) do
      {:ok, {:node, _row}} ->
        Placement.release(task.id)
        :node_possible

      {:ok, {:local, _why}} ->
        :local

      {:error, _} = held ->
        held
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(id) do
    case Ash.get(Workspace, id) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  @doc """
  Does the pass's home clone at `path` hold uncommitted work? Such a pass stays on
  the primary (the seed carries commits, not the work tree). A checkout git cannot
  read counts as holding work: keeping it here is the safe answer.
  """
  @spec local_work?(String.t() | nil) :: boolean()
  def local_work?(path) when is_binary(path) do
    File.dir?(path) and Worktree.has_uncommitted?(path) != {:ok, false}
  rescue
    _ -> true
  end

  def local_work?(_), do: false

  @doc """
  Seed the node `node` was placed on, or fall back to the primary.

  `node` is `place/2`'s answer (`nil` for a local pass: `{:ok, nil, nil}`, nothing
  read). `ctx`: `:task_id`, `:path` (the home clone), `:branch`, `:target`,
  `:mode` (`worker.placement`), `:repo_path` and `:seed_paths`.

  A clone the forge cannot be reconciled with (`seed/3`'s errors) cannot be
  handed to a node: under `prefer_remote` the slot is given back and the pass
  runs on the primary, its clone given the deps a thin node clone was cut without;
  under `remote_only` there is no primary to fall back to and the error stands.
  """
  @spec seed_or_local(map() | nil, map()) ::
          {:ok, map() | nil, seed() | nil} | {:error, {:remote_seed_failed, term()}}
  def seed_or_local(nil, _ctx), do: {:ok, nil, nil}

  def seed_or_local(node, %{path: path, branch: branch, target: target} = ctx) do
    case seed(path, branch, target) do
      {:ok, seed} ->
        {:ok, node, seed}

      {:error, reason} ->
        release(ctx.task_id)

        if ctx.mode == :remote_only do
          {:error, {:remote_seed_failed, reason}}
        else
          Logger.warning(
            "PassPlacement: #{ctx.task_id} cannot be seeded to #{node_name(node)} " <>
              "(#{inspect(reason, limit: 10)}); running on the primary"
          )

          # A clone cut thin for a node has no deps; one the caller seeded already
          # (`repo_path: nil`) does.
          if is_binary(ctx.repo_path),
            do: Worktree.seed_worktree(ctx.repo_path, path, ctx.seed_paths)

          {:ok, nil, nil}
        end
    end
  end

  defp node_name(%{name: name}) when is_binary(name), do: name
  defp node_name(_), do: "the node"

  @doc """
  A pass's agent did not start on `node`. A node's own refusal
  (`Arbiter.Nodes.Refusal`) is a hold, not a failure: the run is interrupted with
  the typed `:placement_refused` cause (no attempt consumed) and the caller
  returns `{:error, {:no_node_capacity, info}}`, which the Watchdog asks again
  on. Anything else fails the pass's worker (`:spawn_failed`, as
  `PassAdmission.agent_failed/2` does). Returns the error to hand back.
  """
  @spec start_failed(String.t(), pid(), map() | nil, term()) :: {:error, term()}
  def start_failed(task_id, worker_pid, node, reason) do
    case node && Refusal.from_start_error(reason) do
      {:ok, refusal} ->
        name = node_name(node)
        cause = StopReason.placement_refused(name, refusal.reason, refusal[:detail])

        _ =
          try do
            Worker.interrupt(worker_pid, cause)
          catch
            :exit, _ -> :ok
          end

        {:error, {:no_node_capacity, Refusal.info(task_id, name, refusal)}}

      _ ->
        _ = Worker.fail(worker_pid, StopReason.spawn_failed(reason))
        {:error, reason}
    end
  end

  @doc """
  Refresh the home clone at `path` from the forge before the node is seeded from
  it: fetch `origin/<branch>` and `origin/<target>`, then bring the local
  `branch` up to the forge head. See the moduledoc.
  """
  @spec seed(String.t(), String.t(), String.t()) :: {:ok, seed()} | {:error, term()}
  def seed(path, branch, target) do
    with {:ok, tips} <- fetch_tips(path, branch, target),
         remote_head = Map.fetch!(tips, branch),
         {:ok, alignment} <- align(path, branch, remote_head) do
      {:ok, %{remote_head: remote_head, target_tip: Map.fetch!(tips, target), alignment: alignment}}
    end
  end

  defp fetch_tips(path, branch, target) do
    case Worktree.fetch_origin_tips(path, Enum.uniq([branch, target])) do
      {:ok, tips} -> {:ok, tips}
      {:error, {:fetch_failed, msg}} -> {:error, {:seed_fetch_failed, msg}}
    end
  end

  defp align(path, branch, remote_head) do
    case Worktree.align_branch(path, branch, remote_head) do
      {:ok, alignment} -> {:ok, alignment}
      {:error, {:diverged, local, remote}} -> {:error, {:seed_diverged, local, remote}}
      {:error, reason} -> {:error, {:seed_align_failed, reason}}
    end
  end
end
