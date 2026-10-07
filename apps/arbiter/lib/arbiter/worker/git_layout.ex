defmodule Arbiter.Worker.GitLayout do
  @moduledoc """
  Which git layout a worker checkout gets (bd-4wy1w1, P5 of
  `docs/design/podman-worker-containers.md`):

    * `:linked_worktree` (layout A) — `git worktree add`, registered in the
      main repo, sharing its refs, config and hooks. Every bwrap-jailed and
      unjailed worker.
    * `:private_clone` (layout B, `Arbiter.Worker.PrivateClone`) — its own
      `.git`, the main repo's objects borrowed read-only. A container worker:
      mounting a linked worktree into a container means mounting the main
      repo's shared `refs/` and `logs/` read-write, which lets the worker
      rewrite any sibling's branch (the P1 spike's probe).

  The layout follows the sandbox backend of the `SecurityPolicy` the spawn
  resolves (`sandbox.backend: podman` → `:private_clone`), so a checkout and
  the sandbox it is mounted into cannot disagree.
  """

  alias Arbiter.Agents.SecurityPolicy

  @type t :: :linked_worktree | :private_clone

  @doc "The layout for a spawn under `policy`."
  @spec for_policy(SecurityPolicy.t()) :: t()
  def for_policy(%SecurityPolicy{} = policy) do
    case SecurityPolicy.sandbox_backend(policy) do
      :podman -> :private_clone
      _ -> :linked_worktree
    end
  end

  @doc """
  The layout a ReviewGate reviewer's checkout gets under `policy` (bd-7ays3v):
  `:private_clone` when the review may run in a container
  (`SecurityPolicy.review_container?/1`: `sandbox.backend` or
  `sandbox.review_backend` is podman), else `:linked_worktree`. The merge
  queue's fix and conflict passes need no counterpart: they run under the
  implement backend, so `for_policy/1` is already theirs.
  """
  @spec for_review_policy(SecurityPolicy.t()) :: t()
  def for_review_policy(%SecurityPolicy{} = policy),
    do: if(SecurityPolicy.review_container?(policy), do: :private_clone, else: :linked_worktree)

  @doc """
  `for_review_policy/1` for the policy a reviewer in `workspace` and `repo`
  resolves (`SecurityPolicy.resolve/3`).
  """
  @spec for_review_workspace(term(), String.t() | nil) :: t()
  def for_review_workspace(workspace, repo \\ nil),
    do: workspace |> SecurityPolicy.resolve(%{}, repo) |> for_review_policy()

  @doc """
  The layout for a spawn in `workspace` (a struct, a config-bearing map or
  `nil`), scoped to `repo` and a per-dispatch security `override`, resolved
  exactly as the spawn's own policy is (`SecurityPolicy.resolve/3`).
  """
  @spec for_workspace(term(), String.t() | nil, map()) :: t()
  def for_workspace(workspace, repo \\ nil, override \\ %{}),
    do: workspace |> SecurityPolicy.resolve(override, repo) |> for_policy()
end
