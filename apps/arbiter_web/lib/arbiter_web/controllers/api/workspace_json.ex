defmodule ArbiterWeb.Api.WorkspaceJSON do
  @moduledoc "Render functions for Workspace resources."

  alias Arbiter.Agents
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace

  def show(%{workspace: ws}), do: data(ws)

  def index(%{workspaces: workspaces}) do
    %{data: Enum.map(workspaces, &data/1)}
  end

  def data(%Workspace{} = ws) do
    adapter = Agents.for_workspace(ws)
    policy = SecurityPolicy.resolve(ws)

    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config,
      # Names of the configured secrets ONLY — never the decrypted values. This
      # lets `arb workspace secret ls` show what's set without exposing tokens.
      # The encrypted `secrets`/`encrypted_secrets` is deliberately never
      # serialised; reference a secret from config via `credentials_ref: "secret:<key>"`.
      secret_keys: secret_key_names(ws),
      # User-defined worker env vars: names + per-key secret flags ONLY, never
      # the (encrypted) values. Secret-flagged values are additionally redacted
      # from worker output — see Arbiter.Worker.WorkerEnv / Arbiter.Redaction.
      worker_env: worker_env_keys(ws),
      # The *resolved* worker security posture (install default + this
      # domain's overrides) — single source of truth for `arb prime` and the
      # dashboard, so neither re-derives it from raw config.
      # `policy_enforced` reflects whether the active adapter honors the policy
      # contract (see Arbiter.Agents.Agent.security_enforced?/0). Adapters that
      # don't yet implement the security contract return false so the operator
      # knows the declared posture is not being enforced.
      # `write_confinement` (bd-1abj7u) names WHAT confines this adapter's
      # writes to the worktree under the resolved policy — `:os_jail`,
      # `:permission_layer`, or `:none` when nothing does (see
      # Arbiter.Agents.Agent.write_confinement/1 and
      # docs/design/agy-strict-write-isolation.md). Distinct from
      # `policy_enforced`: an adapter can enforce its own deny-list contract
      # while still answering `:none` here (agy/Gemini).
      # `write_jail_warning` (bd-3s82pf) is non-nil exactly when that `:none`
      # is a degraded state rather than "not applicable" — outside `:strict`
      # dispatch never refuses on it, so this is the only place it surfaces.
      # `repos` (bd-8xy1mf) carries the same shape per `agent.security.repos`
      # override — a repo can resolve `:strict` while the workspace default
      # doesn't, and `SecurityPolicy.resolve/3`'s repo layer only kicks in
      # when a `repo` argument is passed, so the workspace-level `policy`
      # above never sees it. `arb server doctor`'s AC3 "some workspace/repo
      # resolves :strict" needs this to catch that case.
      security_posture:
        policy
        |> SecurityPolicy.summary()
        |> Map.merge(%{
          "provider" => adapter.provider(),
          "policy_enforced" => security_enforced?(adapter),
          "write_confinement" => Agents.write_confinement(adapter, policy),
          "write_jail_warning" => Agents.write_jail_warning(adapter, policy),
          "repos" => repo_security_postures(ws, adapter)
        }),
      created_at: iso(ws.created_at),
      updated_at: iso(ws.updated_at)
    }
  end

  # Sorted key names of the workspace's secrets (values are NEVER returned).
  # Decrypts the stored column on demand via `Workspace.secrets_map/1`.
  defp secret_key_names(%Workspace{} = ws) do
    ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort()
  end

  # Worker env var names + secret flags (never values). Derived from the public
  # `worker_env_meta`, so this never decrypts anything.
  defp worker_env_keys(%Workspace{} = ws) do
    ws
    |> Workspace.worker_env_keys()
    |> Enum.map(fn %{name: name, secret?: secret?} -> %{name: name, secret: secret?} end)
  end

  # `%{repo_name => %{"mode" => ..., "write_jail_warning" => ...}}` for every
  # repo with an explicit `agent.security.repos.<repo>` override — a repo not
  # listed there resolves identically to the workspace-level `policy` already
  # covered above (`SecurityPolicy.repo_override/2` is a no-op merge when the
  # key is absent), so there's nothing new to report for it.
  defp repo_security_postures(%Workspace{} = ws, adapter) do
    ws.config
    |> Kernel.||(%{})
    |> get_in(["agent", "security", "repos"])
    |> case do
      repos when is_map(repos) ->
        Map.new(repos, fn {repo, _override} ->
          repo_policy = SecurityPolicy.resolve(ws, %{}, repo)

          {repo,
           %{
             "mode" => Atom.to_string(repo_policy.permissions.mode),
             "write_jail_warning" => Agents.write_jail_warning(adapter, repo_policy)
           }}
        end)

      _ ->
        %{}
    end
  end

  defp security_enforced?(adapter) do
    if function_exported?(adapter, :security_enforced?, 0) do
      adapter.security_enforced?()
    else
      false
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
