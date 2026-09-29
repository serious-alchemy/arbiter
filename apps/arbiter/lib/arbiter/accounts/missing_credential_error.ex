defmodule Arbiter.Accounts.MissingCredentialError do
  @moduledoc """
  Raised when the workspace a spawn is for has no account credential to
  supply a provider credential the workspace demonstrably still needs (P3 /
  bd-aiodva, `docs/provider-account-design.md` §7.5 "Release N+1"). Since the
  P13 flip (bd-9gqj8e) provider accounts are the only credential source, so
  there is no legacy chain to fall back to.

  This is the acceptance-3 guarantee of the read flip: the failure mode the
  flip must never have is a *silent* one — a worker dispatched with no token,
  which authenticates as nobody, 401s several minutes in and burns a run
  before anyone notices. The flip fails loudly at the point the credential is
  resolved instead.

  It fires only when the credential would actually be lost: the workspace's
  `worker_env` blob still carries it, and the account tables do not. A
  workspace that never had a provider credential resolves to "no credential"
  and never raises — nothing is being taken away.

  The fix: run `mix arbiter.accounts.migrate` (a release install:
  `Arbiter.Release.accounts_migrate/1`) for the workspace, so the credential
  it already holds becomes an account row — or attach an account that holds
  one and remove the key from the workspace's `worker_env`.
  """

  defexception [:workspace_id, :env_vars, :message]

  @type t :: %__MODULE__{
          workspace_id: String.t() | nil,
          env_vars: [String.t()],
          message: String.t()
        }

  @impl true
  def exception(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    env_vars = opts |> Keyword.get(:env_vars, []) |> List.wrap()

    %__MODULE__{
      workspace_id: workspace_id,
      env_vars: env_vars,
      message: build_message(workspace_id, env_vars)
    }
  end

  defp build_message(workspace_id, env_vars) do
    "workspace #{workspace_id || "(unknown)"} has no active provider account " <>
      "credential for #{vars(env_vars)}, while its worker_env still supplies one — " <>
      "provider accounts are the only credential source, so dispatching would hand " <>
      "the worker no credential at all. Run `mix arbiter.accounts.migrate` for this " <>
      "workspace (docs/provider-accounts-release-runbook.md)."
  end

  defp vars([]), do: "its provider credential"
  defp vars(env_vars), do: Enum.join(env_vars, ", ")
end
