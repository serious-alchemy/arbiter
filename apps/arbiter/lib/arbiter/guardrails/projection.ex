defmodule Arbiter.Guardrails.Projection do
  @moduledoc """
  What a spawn is actually given: the ticket's declared permissions turned into
  exactly the reach a worker gets, and nothing else
  (`docs/design/guardrail-profiles.md` §5.5, G14). **Undeclared means
  withheld**: not denied at the tool layer, but absent from the env, the jail's
  mounts, the proxy allowlist and the MCP claims.

  Pure: no DB, no config reads, **no secret values**. `env` holds
  `{env_var, secret_name}` pairs; the value is looked up at spawn time
  (`Arbiter.Worker.WorkerEnv`), so a projection can ride in spawn opts and be
  logged or recorded without leaking one.

  ## What each permission projects

  | Permission | env | hosts (proxy allowlist) | tunnels | ssh agent | claims |
  |---|---|---|---|---|---|
  | `network:h:p` | | `h:p` | | | |
  | `tracker_write` | `GH_TOKEN` (the binding's `token_env`) from `token_secret` | `api.github.com:443` | | | `tracker_write` |
  | `secrets:<n>` | the binding's `env_from_secret` | the binding's `hosts` | | | |
  | `prod_read` | the binding's `env_from_secret` | the binding's `hosts` | the binding's `tunnels` | | |
  | `prod_ssh` | | the binding's `hosts` (`host:22`) | | the binding's `ssh_key_secret` | |

  `research_read` projects nothing here (`Arbiter.Worker.ResearchGrant` owns it: it needs no
  guardrail profile). A data class (`phi_data`) projects no reach: it only limits which subjects may
  be routed to (G13).

  ## When a permission is withheld although declared

    * the **role** is a reviewer: reviewers get no action permissions (§5.4);
    * the profile is **out of scope** for this workspace/repo;
    * the profile's tier does not list the kind (`profile.permissions`);
    * the tier is below the binding's `min_tier` (or the §5.1 default);
    * the workspace has **no binding** for a kind that needs one, or the binding
      lacks what the kind projects (`prod_ssh` without `ssh_key_secret`).

  Each is recorded in `withheld` with its reason, which the worker prompt's
  PERMISSIONS block shows. Routing (G13) is what refuses to dispatch such a
  ticket to an ineligible subject; this is the second fence if one gets here.

  ## Guarded or not

  `guarded?: false` (`build/2` with no profile, i.e. no subject rule is
  configured — `Arbiter.Guardrails.effective/4` is `nil`) means this module has
  no opinion and spawns behave exactly as before G14. `sealed/0` is the
  fail-closed value for a guarded spawn whose projection was not computed.
  """

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Permissions
  alias Arbiter.Guardrails.Profile
  alias Arbiter.Worker.Egress.Policy, as: EgressPolicy

  defstruct guarded?: false,
            profile: nil,
            role: :implementer,
            granted: [],
            withheld: [],
            env: [],
            hosts: [],
            tunnels: [],
            ssh: nil,
            claims: [],
            tracker_env: nil

  @type tunnel :: {:inet.port_number(), String.t(), :inet.port_number()}
  @type t :: %__MODULE__{
          guarded?: boolean(),
          profile: Profile.t() | nil,
          role: :implementer | :reviewer,
          granted: [String.t()],
          withheld: [%{permission: String.t(), reason: String.t()}],
          env: [{String.t(), String.t()}],
          hosts: [String.t()],
          tunnels: [tunnel()],
          ssh: nil | %{key_secret: String.t(), hosts: [String.t()]},
          claims: [String.t()],
          tracker_env: String.t() | nil
        }

  @github_api "api.github.com:443"
  @default_token_env "GH_TOKEN"

  # §5.1 default `min_tier`, per kind.
  @default_min_tier %{
    network: :probation,
    tracker_write: :trusted,
    secrets: :trusted,
    prod_read: :privileged,
    prod_ssh: :privileged
  }

  # `Profile.permissions` entry that admits a kind.
  @profile_entry %{
    network: "network:",
    tracker_write: "tracker_write",
    secrets: "secrets:",
    prod_read: "prod_read",
    prod_ssh: "prod_ssh"
  }

  @doc "The projection of a spawn with no guardrail profile: no opinion, legacy behaviour."
  @spec unguarded() :: t()
  def unguarded, do: %__MODULE__{guarded?: false}

  @doc "A guarded spawn that is given nothing: the fail-closed value."
  @spec sealed(keyword()) :: t()
  def sealed(opts \\ []),
    do: %__MODULE__{guarded?: true, role: Keyword.get(opts, :role, :implementer)}

  @doc """
  Project `permissions` (canonical strings, in force) for a spawn.

  Options: `:profile` (`Arbiter.Guardrails.Profile` or `nil`), `:block` (the
  workspace `guardrails` block, string keys), `:role` (`:implementer`, the
  default, or `:reviewer`).
  """
  @spec build([String.t()], keyword()) :: t()
  def build(permissions, opts) when is_list(permissions) do
    role = Keyword.get(opts, :role, :implementer)
    block = Keyword.get(opts, :block) || %{}

    case Keyword.get(opts, :profile) do
      nil ->
        unguarded()

      %Profile{} = profile ->
        permissions
        |> Enum.flat_map(&parse/1)
        |> Enum.reject(&(&1.kind in [:phi_data, :research_read]))
        |> Enum.reduce(%{sealed(role: role) | profile: profile}, &project(&1, &2, profile, block))
        |> finish()
    end
  end

  defp parse(raw) do
    case Permissions.parse(raw) do
      {:ok, parsed} -> [parsed]
      {:error, _} -> []
    end
  end

  defp project(parsed, acc, profile, block) do
    binding = Permissions.binding(block, parsed)

    with :ok <- check_role(acc.role),
         :ok <- check_scope(profile),
         :ok <- check_tier(parsed.kind, binding, profile),
         :ok <- check_profile(parsed.kind, profile),
         {:ok, reach} <- reach(parsed, binding) do
      merge(acc, parsed.canonical, reach)
    else
      {:withhold, reason} ->
        %{acc | withheld: acc.withheld ++ [%{permission: parsed.canonical, reason: reason}]}
    end
  end

  defp check_role(:implementer), do: :ok
  defp check_role(_), do: {:withhold, "reviewers get no action permissions"}

  defp check_scope(%Profile{in_scope?: false}),
    do: {:withhold, "the subject's guardrail scope excludes this workspace or repo"}

  defp check_scope(_), do: :ok

  defp check_profile(kind, %Profile{tier: tier, permissions: allowed}) do
    if Map.fetch!(@profile_entry, kind) in allowed,
      do: :ok,
      else: {:withhold, "the #{tier} guardrail profile does not permit #{kind}"}
  end

  defp check_tier(kind, binding, %Profile{tier: tier}) do
    min = min_tier(kind, binding)

    if Guardrails.tier_rank(tier) >= Guardrails.tier_rank(min),
      do: :ok,
      else: {:withhold, "tier #{tier} is below #{min}, which #{kind} needs"}
  end

  defp min_tier(kind, binding) do
    explicit = binding && Arbiter.Guardrails.Config.tier(Map.get(binding, "min_tier"))
    explicit || default_min_tier(kind, binding)
  end

  defp default_min_tier(:secrets, %{"tags" => tags}) when is_list(tags),
    do: if("prod" in tags, do: :privileged, else: :trusted)

  defp default_min_tier(kind, _binding), do: Map.fetch!(@default_min_tier, kind)

  # ---- what a permission reaches ----------------------------------------------

  defp reach(%{kind: :network, canonical: canonical}, _binding) do
    host = canonical |> required() |> String.replace_prefix("network:", "")
    {:ok, %{hosts: [host]}}
  end

  defp reach(%{kind: :tracker_write}, binding) do
    token =
      case binding && Map.get(binding, "token_secret") do
        secret when is_binary(secret) and secret != "" ->
          [{Map.get(binding, "token_env") || @default_token_env, secret}]

        _ ->
          []
      end

    var = (binding && Map.get(binding, "token_env")) || @default_token_env

    {:ok,
     %{
       env: token,
       hosts: [@github_api | hosts(binding, 443)],
       claims: ["tracker_write"],
       tracker_env: var
     }}
  end

  defp reach(%{kind: kind, canonical: canonical}, nil)
       when kind in [:secrets, :prod_read, :prod_ssh],
       do: {:withhold, "no binding for #{required(canonical)} in this workspace"}

  defp reach(%{kind: :secrets}, binding),
    do: {:ok, %{env: env(binding), hosts: hosts(binding, 443)}}

  defp reach(%{kind: :prod_read}, binding) do
    {:ok, %{env: env(binding), hosts: hosts(binding, 443), tunnels: tunnels(binding)}}
  end

  defp reach(%{kind: :prod_ssh}, binding) do
    case Map.get(binding, "ssh_key_secret") do
      secret when is_binary(secret) and secret != "" ->
        hosts = hosts(binding, 22)
        {:ok, %{hosts: hosts, ssh: %{key_secret: secret, hosts: hosts}}}

      _ ->
        {:withhold, "the prod_ssh binding has no ssh_key_secret"}
    end
  end

  defp required(canonical), do: Permissions.required_form(canonical)

  defp env(binding) do
    case Map.get(binding, "env_from_secret") do
      %{} = map ->
        map |> Enum.sort() |> Enum.filter(fn {k, v} -> is_binary(k) and is_binary(v) end)

      _ ->
        []
    end
  end

  defp hosts(nil, _port), do: []

  defp hosts(binding, default_port) do
    # Ticket grants never wildcard (`Egress.Policy.normalize_grant/1` refuses one).
    for entry <- List.wrap(Map.get(binding, "hosts")),
        is_binary(entry),
        authority = if(String.contains?(entry, ":"), do: entry, else: "#{entry}:#{default_port}"),
        {:ok, canonical} <- [EgressPolicy.normalize_grant(authority)],
        do: canonical
  end

  # "HOST:PORT" bridges 127.0.0.1:PORT; "LOCAL:HOST:PORT" picks the local port.
  defp tunnels(binding) do
    for entry <- List.wrap(Map.get(binding, "tunnels")),
        is_binary(entry),
        t <- parse_tunnel(entry),
        do: t
  end

  defp parse_tunnel(entry) do
    with parts when length(parts) in [2, 3] <- String.split(entry, ":"),
         {port, ""} when port in 1..65_535 <- Integer.parse(List.last(parts)),
         host = parts |> Enum.at(-2) |> String.downcase(),
         true <- host != "",
         {:ok, local} <- local_port(parts, port) do
      [{local, host, port}]
    else
      _ -> []
    end
  end

  defp local_port([_host, _port], remote), do: {:ok, remote}

  defp local_port([local, _host, _port], _remote) do
    case Integer.parse(local) do
      {n, ""} when n in 1..65_535 -> {:ok, n}
      _ -> :error
    end
  end

  defp merge(acc, canonical, reach) do
    %{
      acc
      | granted: acc.granted ++ [canonical],
        env: acc.env ++ Map.get(reach, :env, []),
        hosts: acc.hosts ++ Map.get(reach, :hosts, []),
        tunnels: acc.tunnels ++ Map.get(reach, :tunnels, []),
        ssh: Map.get(reach, :ssh) || acc.ssh,
        claims: acc.claims ++ Map.get(reach, :claims, []),
        tracker_env: Map.get(reach, :tracker_env) || acc.tracker_env
    }
  end

  defp finish(%__MODULE__{} = p) do
    %{
      p
      | granted: p.granted |> Enum.map(&required/1) |> Enum.uniq() |> Enum.sort(),
        env: Enum.uniq(p.env),
        hosts: Enum.uniq(p.hosts),
        tunnels: Enum.uniq(p.tunnels),
        claims: Enum.uniq(p.claims)
    }
  end

  @doc """
  A JSON-friendly summary for a run record or the prompt: names only, never a
  secret value (nor a secret's name — only the env vars it lands in).
  """
  @spec to_decision(t()) :: map()
  def to_decision(%__MODULE__{} = p) do
    %{
      "guarded" => p.guarded?,
      "role" => Atom.to_string(p.role),
      "granted" => p.granted,
      "withheld" =>
        Enum.map(p.withheld, &%{"permission" => &1.permission, "reason" => &1.reason}),
      "env" => Enum.map(p.env, &elem(&1, 0)),
      "hosts" => p.hosts,
      "tunnels" => Enum.map(p.tunnels, fn {local, host, port} -> "#{local}:#{host}:#{port}" end),
      "ssh_agent" => p.ssh != nil,
      "claims" => p.claims
    }
  end
end
