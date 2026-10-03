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
  The layout for a spawn in `workspace` (a struct, a config-bearing map or
  `nil`), scoped to `repo` and a per-dispatch security `override`, resolved
  exactly as the spawn's own policy is (`SecurityPolicy.resolve/3`).
  """
  @spec for_workspace(term(), String.t() | nil, map()) :: t()
  def for_workspace(workspace, repo \\ nil, override \\ %{}),
    do: workspace |> SecurityPolicy.resolve(override, repo) |> for_policy()
end
