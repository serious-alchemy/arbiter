defmodule Arbiter.Guardrails.Authority do
  @moduledoc """
  Who may loosen a guardrail (`docs/design/guardrail-profiles.md` §6.4, §7.1).

  **Tightening is always safe; loosening is operator-only.** The coordinator may
  tighten `guardrails.*` and `agent.security`, and may demote a subject; it may
  not raise a tier, widen a scope, loosen a cap or a binding's authority, or
  relax the security posture.

  Authority is a small atom, derived at the entry point and carried to the
  workspace write as the Ash context key `:guardrail_authority`
  (`Arbiter.Tasks.Workspace.Changes.EnforceGuardrailAuthority`):

    * `:operator` — the dashboard (an operator's browser session), the
      operator-proof CLI/REST token (`Scope.operator?/1`), and in-process
      callers (the Loop's operator-gated apply, boot-time migration). The
      default when no authority is given: in-process code is trusted code, and
      every untrusted entry point passes its authority explicitly.
    * `:coordinator` — a coordinator-tier MCP/REST token without operator proof.
    * `:restricted` — anything else (worker, refine, no token).

  The comparison itself is pure: `config_loosenings/2` and `rule_loosenings/2`
  return human-readable reasons, `[]` when the new value is at least as tight.
  What counts as loose for `agent.security` is decided on the **resolved**
  policy (`Arbiter.Guardrails.loosenings/2`) so a deprecated alias or a repo
  override cannot sneak a loosening past a textual diff.
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Config
  alias Arbiter.MCP.Scope

  @type authority :: :operator | :coordinator | :restricted

  @doc "The authority a request with `scope` (`nil` for none) carries."
  @spec from_scope(Scope.t() | nil) :: authority()
  def from_scope(%Scope{tier: :coordinator} = scope),
    do: if(Scope.operator?(scope), do: :operator, else: :coordinator)

  def from_scope(_), do: :restricted

  @doc """
  `:ok`, or `{:error, message}` when `authority` may not make a change with these
  `loosenings`. An empty list (a pure tightening) is always allowed.
  """
  @spec authorize([String.t()], authority()) :: :ok | {:error, String.t()}
  def authorize([], _authority), do: :ok
  def authorize(_loosenings, :operator), do: :ok

  def authorize(loosenings, authority) do
    {:error,
     "loosening a guardrail is operator-only; a #{authority} token may only tighten. " <>
       "Refused: " <> Enum.join(Enum.take(loosenings, 5), "; ") <> more(loosenings)}
  end

  defp more(list) when length(list) > 5, do: " (+#{length(list) - 5} more)"
  defp more(_), do: ""

  # ---- workspace config -----------------------------------------------------

  @doc """
  What changing a workspace `config` from `old` to `new` loosens, across
  `agent.security` (workspace-wide and every `repos.<repo>` layer) and the
  `guardrails` block.
  """
  @spec config_loosenings(map() | nil, map() | nil) :: [String.t()]
  def config_loosenings(old, new) do
    old = old || %{}
    new = new || %{}

    (security_loosenings(old, new) ++ block_loosenings(Config.block(old), Config.block(new)))
    |> Enum.uniq()
  end

  defp security_loosenings(old, new) do
    repos = Enum.uniq(security_repos(old) ++ security_repos(new))

    for repo <- [nil | repos],
        reason <-
          Guardrails.loosenings(
            SecurityPolicy.resolve(%{config: new}, %{}, repo),
            SecurityPolicy.resolve(%{config: old}, %{}, repo)
          ) do
      if repo, do: "agent.security.repos.#{repo}: #{reason}", else: "agent.security: #{reason}"
    end
  end

  defp security_repos(config) do
    case get_in(config, ["agent", "security", "repos"]) do
      %{} = repos -> Map.keys(repos)
      _ -> []
    end
  end

  @doc "What `new_block` loosens relative to `old_block` (both string-keyed `guardrails` blocks)."
  @spec block_loosenings(map(), map()) :: [String.t()]
  def block_loosenings(old, new) do
    subject_loosenings(Map.get(old, "subjects"), Map.get(new, "subjects"), "guardrails.subjects") ++
      binding_loosenings(Map.get(old, "bindings"), Map.get(new, "bindings")) ++
      defaults_loosenings(
        Map.get(old, "defaults"),
        Map.get(new, "defaults"),
        "guardrails.defaults"
      ) ++
      repo_loosenings(Map.get(old, "repos"), Map.get(new, "repos"))
  end

  defp repo_loosenings(old, new) do
    old = map_or_empty(old)
    new = map_or_empty(new)

    for repo <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        o = map_or_empty(Map.get(old, repo)),
        n = map_or_empty(Map.get(new, repo)),
        reason <-
          subject_loosenings(
            Map.get(o, "subjects"),
            Map.get(n, "subjects"),
            "guardrails.repos.#{repo}.subjects"
          ) ++
            defaults_loosenings(
              Map.get(o, "defaults"),
              Map.get(n, "defaults"),
              "guardrails.repos.#{repo}.defaults"
            ) do
      reason
    end
  end

  defp defaults_loosenings(old, new, label) do
    old_p = old |> map_or_empty() |> Map.get("permissions") |> list_or_empty()
    new_p = new |> map_or_empty() |> Map.get("permissions") |> list_or_empty()

    case new_p -- old_p do
      [] -> []
      added -> ["#{label}.permissions adds #{Enum.join(added, ", ")}"]
    end
  end

  # A cap is loosened when it is removed, or when any field moves looser. A new
  # cap, or a tighter one, is not.
  defp subject_loosenings(old, new, label) do
    old_caps = old |> list_or_empty() |> Enum.filter(&is_map/1) |> Enum.map(&Config.parse_cap/1)
    new_caps = new |> list_or_empty() |> Enum.filter(&is_map/1) |> Enum.map(&Config.parse_cap/1)

    Enum.flat_map(old_caps, fn %{match: match, caps: caps} ->
      candidates = Enum.filter(new_caps, &(&1.match == match))

      cond do
        map_size(caps) == 0 -> []
        candidates == [] -> ["#{label}: the cap on #{describe(match)} was removed"]
        Enum.any?(candidates, &(cap_loosenings(caps, &1.caps) == [])) -> []
        true -> ["#{label}: the cap on #{describe(match)} is looser"]
      end
    end)
  end

  defp describe(match), do: match |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

  # Field-by-field "is `new` looser than `old`", over caps parsed by
  # `Config.parse_caps/1`. A field `old` set and `new` dropped is loosened.
  @spec cap_loosenings(map(), map()) :: [String.t()]
  def cap_loosenings(old, new) do
    Enum.flat_map(old, fn {field, old_value} ->
      cap_field(field, old_value, Map.get(new, field))
    end)
  end

  defp cap_field(field, _old, nil), do: ["#{field} dropped"]

  defp cap_field(:max_tier, o, n),
    do: loose_if(Guardrails.tier_rank(n) > Guardrails.tier_rank(o), "max_tier raised")

  defp cap_field(:min_mode, o, n),
    do: loose_if(Guardrails.mode_rank(n) < Guardrails.mode_rank(o), "min_mode lowered")

  defp cap_field(:egress, o, n),
    do: loose_if(Guardrails.egress_rank(n) < Guardrails.egress_rank(o), "egress loosened")

  defp cap_field(:max_difficulty, o, n), do: loose_if(n > o, "max_difficulty raised")

  defp cap_field(:spend, o, n) do
    loose_if(
      Map.get(o, :action) == :park and Map.get(n, :action) == :page,
      "spend action relaxed"
    ) ++
      Enum.flat_map([:tokens, :wall_clock_s], fn key ->
        case {Map.get(o, key), Map.get(n, key)} do
          {nil, _} -> []
          {_, nil} -> ["spend.#{key} dropped"]
          {ov, nv} -> loose_if(nv > ov, "spend.#{key} raised")
        end
      end)
  end

  defp cap_field(:review, o, n) do
    review_rank = %{
      cross_family: %{workspace: 0, required: 1},
      same_family_fallback: %{workspace: 0, record: 1, hold: 2},
      min_reviewer_tier: %{economy: 0, standard: 1, premium: 2}
    }

    Enum.flat_map(o, fn {key, ov} ->
      rank = Map.fetch!(review_rank, key)

      case Map.get(n, key) do
        nil -> ["review.#{key} dropped"]
        nv -> loose_if(Map.fetch!(rank, nv) < Map.fetch!(rank, ov), "review.#{key} relaxed")
      end
    end)
  end

  defp loose_if(true, reason), do: [reason]
  defp loose_if(false, _), do: []

  # Bindings define what a ticket may be granted (G12), so a new binding, or a
  # changed one that grants more, is a loosening. Removing one is not.
  defp binding_loosenings(old, new) do
    old = map_or_empty(old)

    new
    |> map_or_empty()
    |> Enum.flat_map(fn {name, binding} ->
      label = "guardrails.bindings.#{name}"
      binding = map_or_empty(binding)

      case Map.fetch(old, name) do
        :error -> ["#{label} is a new binding"]
        {:ok, prior} -> binding_diff(map_or_empty(prior), binding, label)
      end
    end)
  end

  @grant_by_rank %{"coordinator" => 0, "operator" => 1}

  defp binding_diff(old, new, label) do
    grant_by_loose =
      loose_if(
        Map.get(@grant_by_rank, Map.get(new, "grant_by", "coordinator"), 0) <
          Map.get(@grant_by_rank, Map.get(old, "grant_by", "coordinator"), 0),
        "#{label}.grant_by lowered"
      )

    min_tier_loose =
      loose_if(
        tier_rank_of(Map.get(new, "min_tier")) < tier_rank_of(Map.get(old, "min_tier")),
        "#{label}.min_tier lowered"
      )

    read_only_loose =
      loose_if(
        Map.get(old, "enforced_read_only") == true and Map.get(new, "enforced_read_only") != true,
        "#{label}.enforced_read_only dropped"
      )

    list_loose =
      for key <- ~w(tunnels hosts),
          added = list_or_empty(Map.get(new, key)) -- list_or_empty(Map.get(old, key)),
          added != [],
          do: "#{label}.#{key} adds #{Enum.join(added, ", ")}"

    env_loose =
      for {k, v} <- map_or_empty(Map.get(new, "env_from_secret")),
          Map.get(map_or_empty(Map.get(old, "env_from_secret")), k) != v,
          do: "#{label}.env_from_secret.#{k} is new or changed"

    secret_loose =
      for key <- ~w(ssh_key_secret token_secret),
          Map.get(new, key) != Map.get(old, key) and not is_nil(Map.get(new, key)),
          do: "#{label}.#{key} is new or changed"

    grant_by_loose ++ min_tier_loose ++ read_only_loose ++ list_loose ++ env_loose ++ secret_loose
  end

  defp tier_rank_of(tier) do
    case Config.tier(tier) do
      nil -> 0
      parsed -> Guardrails.tier_rank(parsed)
    end
  end

  # ---- subject rules (the guardrail_subjects table) ---------------------------

  @doc """
  What changing a subject rule from `old` (`nil` for a new rule) to `new` (`nil`
  for a delete) loosens. Both are `Arbiter.Guardrails.Rules` rule maps. A new
  rule is measured against the fail-safe default (quarantine, any scope); a
  delete is a loosening unless the rule was already quarantine.
  """
  @spec rule_loosenings(map() | nil, map() | nil) :: [String.t()]
  def rule_loosenings(old, nil) do
    if old && old.tier != :quarantine,
      do: ["removing a #{old.tier} rule drops its subject back to the default"],
      else: []
  end

  def rule_loosenings(old, new) do
    old = old || %{tier: :quarantine, scope: nil, overrides: %{}, pinned: false}

    loose_if(
      Guardrails.tier_rank(new.tier) > Guardrails.tier_rank(old.tier),
      "tier raised to #{new.tier}"
    ) ++
      scope_loosenings(old.scope, new.scope) ++
      Enum.map(cap_loosenings(old.overrides, new.overrides), &"overrides: #{&1}") ++
      loose_if(old.pinned == true and new.pinned != true, "pin removed")
  end

  defp scope_loosenings(nil, _new), do: []
  defp scope_loosenings(_old, nil), do: ["scope widened to every workspace"]

  defp scope_loosenings(old, new) do
    Enum.flat_map(new, fn {ws, repos} ->
      case Map.fetch(old, ws) do
        :error ->
          ["scope adds workspace #{ws}"]

        {:ok, old_repos} ->
          cond do
            old_repos == [] ->
              []

            repos == [] ->
              ["scope widens #{ws} to every repo"]

            repos -- old_repos != [] ->
              ["scope adds #{ws} repos #{Enum.join(repos -- old_repos, ", ")}"]

            true ->
              []
          end
      end
    end)
  end

  defp map_or_empty(%{} = m) when not is_struct(m), do: Config.stringify(m)
  defp map_or_empty(_), do: %{}

  defp list_or_empty(l) when is_list(l), do: l
  defp list_or_empty(_), do: []
end
