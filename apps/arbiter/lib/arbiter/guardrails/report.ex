defmodule Arbiter.Guardrails.Report do
  @moduledoc """
  The guardrail posture `arb doctor` and the workspace posture API show
  (`docs/design/guardrail-profiles.md` §7.3, "guardrail profiles (G11)"): for
  every workspace, the effective tier of each attached (provider, predicted
  model) subject, and a list of **issues**, config that is inconsistent or
  that this host cannot meet.

  Issue kinds (`issue.kind`):

    * `inert_block` — a workspace has a `guardrails` block but the installation
      has no subject rules, so nothing is enforced.
    * `unmatched_subject` — an attached subject matches no rule and so runs as
      `quarantine`.
    * `out_of_scope` — an attached subject is outside its rule's `scope` for the
      workspace.
    * `write_confinement_none` / `egress_unenforceable` — the subject's tier needs
      a capability its adapter does not have on this host.
    * `dead_cap` — a workspace or repo cap matches none of the attached subjects
      (usually a typo in `match`).
    * `unknown_repo` — `guardrails.repos.<repo>` names a repo the workspace does
      not have.
    * `unreachable_binding` — a binding's `min_tier` is above every tier an
      attached subject holds, so no ticket can be granted it.

  With no rules and no `guardrails` block anywhere the report is `active: false`
  with no issues: nothing is configured, nothing is wrong.
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential

  @tier_ladder ~w(economy standard premium flagship)

  @type issue :: %{kind: atom(), workspace: String.t() | nil, message: String.t()}

  @doc """
  Build the report for `workspaces`. Options: `:rules` (default
  `Arbiter.Guardrails.Rules.all/0`).
  """
  @spec build([map()], keyword()) :: map()
  def build(workspaces, opts \\ []) do
    rules = Keyword.get_lazy(opts, :rules, &Rules.all/0)
    entries = Enum.map(workspaces, &workspace_entry(&1, rules))
    inert = if rules == [], do: Enum.filter(entries, & &1.block?), else: []

    %{
      active: rules != [],
      rules: length(rules),
      workspaces: entries,
      issues:
        Enum.flat_map(entries, & &1.issues) ++
          Enum.map(inert, fn e ->
            issue(
              :inert_block,
              e.workspace,
              "has a guardrails block but no subject rule is configured, so it enforces nothing"
            )
          end)
    }
  end

  @doc """
  One workspace's posture, string-keyed for the REST `security_posture` and MCP
  `workspace_show` (`guardrails`): `active`, each attached subject's tier and
  limits under `subjects`, and the human-readable `issues`.
  """
  @spec posture(map(), keyword()) :: map()
  def posture(ws, opts \\ []) do
    rules = Keyword.get_lazy(opts, :rules, &Rules.all/0)
    entry = workspace_entry(ws, rules)

    %{
      "active" => rules != [],
      "subjects" => Enum.map(entry.subjects, &stringify_keys/1),
      "issues" => Enum.map(entry.issues, & &1.message)
    }
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp workspace_entry(ws, rules) do
    name = ws_name(ws)
    block = Config.block(ws)
    subjects = attached_subjects(ws)

    resolved =
      for {type, subject} <- subjects do
        {subject, Guardrails.effective(subject, ws, nil, rules: rules), Agents.for_type(type)}
      end

    entries =
      Enum.map(resolved, fn {subject, profile, adapter} ->
        subject_entry(ws, subject, profile, adapter, rules)
      end)

    %{
      workspace: name,
      block?: map_size(block) > 0,
      subjects: Enum.map(entries, & &1.entry),
      issues:
        Enum.flat_map(entries, & &1.issues) ++
          cap_issues(ws, block, Enum.map(subjects, &elem(&1, 1))) ++
          binding_issues(name, block, resolved) ++
          secret_issues(ws, name, block) ++ git_credential_issues(ws, name, rules != [])
    }
  end

  defp subject_entry(_ws, subject, nil, _adapter, _rules) do
    %{
      entry: %{provider: subject.provider, model: subject.model, tier: nil, guardrails: "off"},
      issues: []
    }
  end

  defp subject_entry(ws, subject, profile, adapter, rules) do
    name = ws_name(ws)
    rule = Rules.match(rules, subject)
    policy = ws |> SecurityPolicy.resolve() |> Guardrails.floor(profile)

    issues =
      [
        if(is_nil(rule),
          do:
            issue(
              :unmatched_subject,
              name,
              "#{label(subject)} matches no subject rule, so it runs as quarantine"
            )
        ),
        if(not profile.in_scope?,
          do: issue(:out_of_scope, name, "#{label(subject)} is outside its rule's scope here")
        ),
        case Guardrails.enforceable(adapter, policy, profile) do
          :ok ->
            nil

          {:error, reason} ->
            issue(
              reason,
              name,
              "#{label(subject)} is #{profile.tier}, which needs " <>
                "#{need(reason, policy)}; #{subject.provider} cannot provide it on this host"
            )
        end
      ]
      |> Enum.reject(&is_nil/1)

    %{
      entry: %{
        provider: subject.provider,
        model: subject.model,
        tier: Atom.to_string(profile.tier),
        min_mode: Atom.to_string(profile.min_mode),
        egress: Atom.to_string(profile.egress),
        max_difficulty: profile.max_difficulty,
        in_scope: profile.in_scope?,
        matched: not is_nil(rule),
        enforceable:
          not Enum.any?(issues, &(&1.kind in [:write_confinement_none, :egress_unenforceable]))
      },
      issues: issues
    }
  end

  defp need(:write_confinement_none, _), do: "write confinement (a :strict floor)"

  defp need(:egress_unenforceable, policy),
    do: "egress confinement (egress: #{SecurityPolicy.egress(policy)})"

  defp cap_issues(ws, block, subjects) do
    name = ws_name(ws)

    ws_caps = Config.cap_entries(block, nil)

    repo_caps =
      block
      |> Map.get("repos", %{})
      |> map_or_empty()
      |> Enum.flat_map(fn {repo, _} ->
        Enum.map(Config.cap_entries(block, repo) -- ws_caps, &{repo, &1})
      end)

    dead =
      for cap <- ws_caps,
          not Enum.any?(subjects, &Rules.matches?(Config.parse_cap(cap).match, &1)) do
        issue(
          :dead_cap,
          name,
          "guardrails.subjects cap #{inspect(Config.parse_cap(cap).match)} matches no attached subject"
        )
      end ++
        for {repo, cap} <- repo_caps,
            not Enum.any?(subjects, &Rules.matches?(Config.parse_cap(cap).match, &1)) do
          issue(
            :dead_cap,
            name,
            "guardrails.repos.#{repo} cap #{inspect(Config.parse_cap(cap).match)} matches no attached subject"
          )
        end

    known = repo_names(ws)

    unknown =
      for {repo, _} <- block |> Map.get("repos", %{}) |> map_or_empty(),
          known != [],
          repo not in known do
        issue(
          :unknown_repo,
          name,
          "guardrails.repos.#{repo} names a repo this workspace does not have"
        )
      end

    dead ++ unknown
  end

  # G14: every secret a binding names must exist in the workspace's secrets (or
  # as a worker_env var), or dispatch quietly projects nothing for it.
  defp secret_issues(ws, name, block) do
    known = known_secret_names(ws)

    for {perm, binding} <- block |> Map.get("bindings", %{}) |> map_or_empty(),
        secret <- binding_secrets(map_or_empty(binding)),
        secret not in known do
      issue(
        :binding_secret_missing,
        name,
        "binding #{perm} names secret #{secret}, which this workspace does not have"
      )
    end
  end

  # G16 (bd-9cygoo): dispatch refuses a worker that pushes when its repo has no
  # scoped git credential (on a guarded install, or once a `git_credentials` block
  # exists), and refuses one whose credential names a secret that is not there.
  defp git_credential_issues(ws, name, guarded?) do
    block = GitCredential.block(ws)
    known = known_secret_names(ws)

    unconfigured =
      for repo <- repo_names(ws),
          GitCredential.enforced?(ws, guarded?),
          match?(
            {:error, _},
            GitCredential.plan(ws, repo, role: :implementer, guarded?: guarded?)
          ) do
        issue(
          :git_credential_unconfigured,
          name,
          "repo #{repo} has no scoped git credential, so a worker that pushes to it is refused " <>
            "(add git_credentials.repos.#{repo}, or git_credentials.legacy_operator: true)"
        )
      end

    missing =
      for {repo, entry} <- block |> Map.get("repos", %{}) |> map_or_empty(),
          secret <- git_credential_secrets(map_or_empty(entry)),
          secret not in known do
        issue(
          :git_credential_secret_missing,
          name,
          "git_credentials.repos.#{repo} names secret #{secret}, which this workspace does not have"
        )
      end

    unconfigured ++ missing
  end

  defp git_credential_secrets(entry) do
    Enum.filter(
      [entry["key_secret"], entry["token_secret"], entry["private_key_secret"]],
      &is_binary/1
    )
  end

  defp binding_secrets(binding) do
    env = binding |> Map.get("env_from_secret") |> map_or_empty() |> Map.values()
    Enum.filter(env ++ [binding["ssh_key_secret"], binding["token_secret"]], &is_binary/1)
  end

  defp known_secret_names(ws),
    do: Workspace.secret_key_names(ws) ++ Enum.map(Workspace.worker_env_keys(ws), & &1.name)

  defp binding_issues(name, block, resolved) do
    top =
      resolved
      |> Enum.flat_map(fn {_s, profile, _a} ->
        if profile, do: [Guardrails.tier_rank(profile.tier)], else: []
      end)
      |> Enum.max(fn -> nil end)

    if is_nil(top) do
      []
    else
      for {perm, binding} <- block |> Map.get("bindings", %{}) |> map_or_empty(),
          tier = Config.tier(map_or_empty(binding)["min_tier"]),
          tier != nil and Guardrails.tier_rank(tier) > top do
        issue(
          :unreachable_binding,
          name,
          "binding #{perm} needs tier #{tier}, above every attached subject's tier"
        )
      end
    end
  end

  # `{adapter type, subject}` for every provider the workspace may dispatch
  # to, as the routing tiers resolve them. A provider with no named model is a
  # single provider-level subject.
  defp attached_subjects(ws) do
    config = (Map.get(ws, :config) || %{}) |> Config.stringify()
    agent_config = get_in(config, ["agent", "config"]) || %{}

    ws
    |> pool()
    |> Enum.flat_map(fn type ->
      models =
        @tier_ladder
        |> Enum.map(&ModelFamily.model_for_tier(type, &1, agent_config))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case models do
        [] -> [{type, Guardrails.subject(type, nil)}]
        models -> Enum.map(models, &{type, Guardrails.subject(type, &1)})
      end
    end)
    |> Enum.uniq()
  end

  defp pool(ws), do: Enum.uniq(Agents.agent_pool(ws) ++ Agents.reviewer_pool(ws))

  defp repo_names(ws) do
    case get_in(Map.get(ws, :config) || %{}, ["repo_paths"]) do
      %{} = paths -> Map.keys(paths)
      _ -> []
    end
  end

  defp label(%{provider: p, model: nil}), do: p
  defp label(%{provider: p, model: m}), do: "#{p}/#{m}"

  defp ws_name(ws), do: Map.get(ws, :name) || Map.get(ws, :id)

  defp issue(kind, workspace, message), do: %{kind: kind, workspace: workspace, message: message}

  defp map_or_empty(%{} = m), do: m
  defp map_or_empty(_), do: %{}
end
