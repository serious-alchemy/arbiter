defmodule Arbiter.Worker.Withholding do
  @moduledoc """
  Dispatch-time withholding (G14, bd-ld8qde; `docs/design/guardrail-profiles.md`
  §5.5): the DB-facing half of `Arbiter.Guardrails.Projection`. **Undeclared
  means withheld** — a spawn is given exactly the reach the ticket's *in-force*
  permissions project, and nothing else.

    * `projection/4` — the ticket's in-force permissions (declared and not
      pending an operator grant, `Arbiter.Tasks.Permissions.in_force/1`) projected
      under a profile and the workspace's bindings.
    * `grants/2` — the egress proxy's grant loader for the run.
    * `ssh_agent/4` — starts the per-worker `ssh-agent` a `prod_ssh` projection
      asks for.

  The surfaces that consume the projection: the spawn env
  (`Arbiter.Worker.WorkerEnv`), the jail (`Arbiter.Worker.Jail`'s `:ssh_agent`),
  the proxy allowlist and fixed tunnels (`Arbiter.Worker.Egress.JailRun`), the
  MCP scope token's `permissions` claim (`Arbiter.MCP.Scope`) and the worker
  prompt's PERMISSIONS block (`Arbiter.Worker.PromptBuilder`).
  """

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Projection
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.SshAgent

  @doc """
  The projection for `issue` in `workspace` under `profile` (`nil`: guardrails
  are off, so `Projection.unguarded/0`) for `role` (`:implementer` or
  `:reviewer`).
  """
  @spec projection(Issue.t(), map() | nil, Profile.t() | nil, :implementer | :reviewer) ::
          Projection.t()
  def projection(%Issue{} = issue, workspace, profile, role) do
    Projection.build(Permissions.in_force(issue),
      profile: profile,
      block: Config.block(workspace),
      role: role
    )
  end

  @doc """
  The projection for a spawn of `task_id` (a real or ReviewGate-synthetic id)
  running `provider`/`model` in `workspace`: resolves the subject's effective
  profile (`Arbiter.Guardrails.effective/4`) and projects the ticket's in-force
  permissions under it. Options: `:repo`, `:role` (default `:implementer`).

  Fails **closed**: with guardrails on, a ticket that cannot be loaded gets
  `Projection.sealed/1`, never an unguarded spawn. With no subject rule
  configured (`profile == nil`) it is `Projection.unguarded/0` and the spawn is
  exactly what it was before G14.
  """
  @spec for_spawn(String.t() | nil, map() | nil, atom() | String.t(), String.t() | nil, keyword()) ::
          Projection.t()
  def for_spawn(task_id, workspace, provider, model, opts \\ []) do
    role = Keyword.get(opts, :role, :implementer)

    profile =
      Guardrails.effective(
        Guardrails.subject(provider, model),
        workspace,
        Keyword.get(opts, :repo)
      )

    case {profile, load_issue(task_id)} do
      {nil, _} -> Projection.unguarded()
      {%Profile{}, %Issue{} = issue} -> projection(issue, workspace, profile, role)
      {%Profile{}, nil} -> Projection.sealed(role: role)
    end
  end

  defp load_issue(task_id) when is_binary(task_id) and task_id != "" do
    case Ash.get(Issue, ReviewGate.base_task_id(task_id)) do
      {:ok, %Issue{} = issue} -> issue
      _ -> nil
    end
  end

  defp load_issue(_), do: nil

  @doc """
  Whether a spawn of `provider` can honour `projection`. Today only a `prod_ssh`
  projection can be unhonourable: its key reaches the worker as a per-worker agent
  socket bound into a jail, which only agy's jail provides (G7 brings Claude under
  the same jail). Anything else is refused rather than run without the agent it was
  promised, on the operator's own.
  """
  @spec check_spawn(Projection.t() | nil, String.t() | atom() | nil) ::
          :ok | {:error, {:prod_ssh_unsupported, String.t() | nil}}
  def check_spawn(%Projection{ssh: ssh}, provider) when not is_nil(ssh) do
    case provider && to_string(provider) do
      "gemini" -> :ok
      other -> {:error, {:prod_ssh_unsupported, other}}
    end
  end

  def check_spawn(_projection, _provider), do: :ok

  @doc """
  The `Arbiter.Worker.Egress` grants loader (`fn task_id -> [\"host:port\"]`)
  for a run of `task_id`.

  A **guarded** spawn gets exactly what its projection granted: the proxy never
  widens past the dispatch-time decision (a mid-run `network:` grant applies live
  with G15). An unguarded spawn reads the ticket's in-force `network:` entries on
  each cache miss, so a declared host works wherever `sandbox.egress: allowlist`
  is on without any guardrail rule.
  """
  @spec grants(String.t() | nil, Projection.t()) :: (String.t() | nil -> [String.t()])
  def grants(_task_id, %Projection{guarded?: true, hosts: hosts}), do: fn _ -> hosts end

  def grants(_task_id, %Projection{}) do
    fn task_id -> live_network_grants(task_id) end
  end

  defp live_network_grants(task_id) when is_binary(task_id) do
    case Ash.get(Issue, ReviewGate.base_task_id(task_id)) do
      {:ok, %Issue{} = issue} ->
        issue
        |> Permissions.in_force()
        |> Enum.map(&Vocabulary.required_form/1)
        |> Enum.filter(&String.starts_with?(&1, "network:"))
        |> Enum.map(&String.replace_prefix(&1, "network:", ""))

      _ ->
        []
    end
  end

  defp live_network_grants(_), do: []

  @doc """
  Starts the per-worker agent a `prod_ssh` projection asks for and returns its
  socket (`{:ok, nil}` when the projection has none). The key is the workspace
  secret the binding names; an absent secret is `{:error, {:ssh_key_missing,
  name}}` — a `prod_ssh` worker is never started without its agent, and never
  given another. `opts`: `:dir`.
  """
  @spec ssh_agent(Projection.t(), map() | nil, pid(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ssh_agent(projection, workspace, owner, opts \\ [])

  def ssh_agent(%Projection{ssh: nil}, _workspace, _owner, _opts), do: {:ok, nil}

  def ssh_agent(%Projection{ssh: %{key_secret: name}}, %Workspace{} = ws, owner, opts) do
    case Map.get(Map.merge(Workspace.worker_env_map(ws), Workspace.secrets_map(ws)), name) do
      key when is_binary(key) and key != "" ->
        with {:ok, %{socket: socket}} <-
               SshAgent.start([owner: owner, key: key] ++ Keyword.take(opts, [:dir])),
             do: {:ok, socket}

      _ ->
        {:error, {:ssh_key_missing, name}}
    end
  end

  def ssh_agent(%Projection{}, _workspace, _owner, _opts), do: {:error, {:ssh_key_missing, nil}}
end
