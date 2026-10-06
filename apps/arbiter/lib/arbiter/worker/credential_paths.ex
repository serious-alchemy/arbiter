defmodule Arbiter.Worker.CredentialPaths do
  @moduledoc """
  The one list of operator-home credential locations a worker must not reach.

  Two enforcement layers consume it so they cannot drift apart:

    * `Arbiter.Worker.Jail.Hide` masks these paths for **jailed** workers
      (kernel-level: the path does not exist in the worker's mount namespace).
    * `Arbiter.Agents.Claude.Security` denies the Read tool (and common
      shell read-tools) on them for **permission-layer** Claude workers,
      which have no sandbox backend and otherwise see the operator's home
      directly (bd-9zi4ok: a worker's bare `kubectl` used `~/.kube/config`).

  Entries are relative to the operator's home. The permission layer is a
  safety net, not a jail; see the `Claude.Security` moduledoc.
  """

  @dirs ~w(.claude .codex .grok .gemini .config/gh .config/gcloud .ssh .aws .kube .docker)
  @files ~w(.netrc .pgpass .git-credentials)

  @doc "Credential directories, relative to the operator's home."
  @spec dirs() :: [String.t()]
  def dirs, do: @dirs

  @doc "Credential files, relative to the operator's home."
  @spec files() :: [String.t()]
  def files, do: @files
end
