defmodule Arbiter.Guardrails.Config do
  @moduledoc """
  The workspace `guardrails` config block: reading it and validating it
  (`docs/design/guardrail-profiles.md` §7.1). The shape:

      "guardrails": {
        "bindings": {"prod_read": {"grant_by": "coordinator", "min_tier": "privileged", ...}},
        "defaults": {"permissions": ["network:repo.hex.pm"]},
        "repos":    {"tonic": {"defaults": {...}, "subjects": [...]}},
        "subjects": [{"match": {"provider": "antigravity"}, "max_tier": "probation"}]
      }

  `subjects` entries are **caps**: a workspace can lower a subject's tier or
  tighten its `min_mode` / `egress` / `max_difficulty` / `spend` / `review`,
  never raise them (§3.5). `bindings` and `defaults` are the ticket-permission
  vocabulary G12 consumes; this module only checks their shape.

  `validate/1` backs `Arbiter.Tasks.Workspace.Changes.ValidateConfig`.
  """

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Permissions
  alias Arbiter.Worker.Egress.Policy, as: EgressPolicy

  @block_keys ~w(bindings defaults repos subjects)
  @repo_keys ~w(defaults subjects)
  @match_keys ~w(provider family model)
  @cap_keys ~w(match max_tier min_mode egress max_difficulty spend review)
  @binding_keys ~w(grant_by min_tier enforced_read_only tunnels hosts env_from_secret token_env
                   ssh_key_secret token_secret tags)
  @grant_by ~w(operator coordinator)
  @cross_family ~w(required workspace)
  @fallbacks ~w(hold record workspace)
  @reviewer_tiers ~w(economy standard premium)
  # A binding key: `prod_read`, `network:<host>`, `secrets:<name>`, ... Only keeps
  # a key from being free text; the vocabulary itself is
  # `Arbiter.Guardrails.Permissions`'s, which `defaults` are checked against.
  @permission_re ~r/^[a-z][a-z0-9_]*(:[^\s:][^\s]*)?$/

  @doc "The workspace's `guardrails` block (string keys), or `%{}`."
  @spec block(map() | nil) :: map()
  def block(%{config: %{} = config}), do: block_of(config)
  def block(%{"config" => %{} = config}), do: block_of(config)
  def block(%{} = config) when not is_struct(config), do: block_of(config)
  def block(_), do: %{}

  defp block_of(config) do
    case Map.get(config, "guardrails") || Map.get(config, :guardrails) do
      %{} = b -> stringify(b)
      _ -> %{}
    end
  end

  @doc "True when the workspace config carries a non-empty `guardrails` block."
  @spec configured?(map() | nil) :: boolean()
  def configured?(workspace), do: block(workspace) != %{}

  @doc "The block's workspace-wide `subjects` caps, followed by `repo`'s own (when named)."
  @spec cap_entries(map(), String.t() | nil) :: [map()]
  def cap_entries(block, repo) do
    ws_caps = list_of_maps(Map.get(block, "subjects"))

    repo_caps =
      with repo when is_binary(repo) and repo != "" <- repo,
           %{} = repos <- Map.get(block, "repos"),
           %{} = entry <- Map.get(repos, repo) do
        list_of_maps(Map.get(entry, "subjects"))
      else
        _ -> []
      end

    ws_caps ++ repo_caps
  end

  @doc """
  Parse one cap entry into `%{match: %{...}, caps: %{...}}`. Invalid values are
  dropped (an unparsable cap is not a cap) — `validate/1` is what refuses them
  on write.
  """
  @spec parse_cap(map()) :: %{match: map(), caps: map()}
  def parse_cap(entry) when is_map(entry) do
    entry = stringify(entry)

    %{
      match: parse_match(Map.get(entry, "match")),
      caps: parse_caps(entry)
    }
  end

  @doc "The cap fields of `map` (a cap entry, a rule's overrides, or an app-env override) parsed."
  @spec parse_caps(map()) :: map()
  def parse_caps(map) when is_map(map) do
    map = stringify(map)

    [
      max_tier: tier(Map.get(map, "max_tier") || Map.get(map, "tier")),
      min_mode: mode(Map.get(map, "min_mode")),
      egress: egress(Map.get(map, "egress")),
      max_difficulty: difficulty(Map.get(map, "max_difficulty")),
      spend: parse_spend(Map.get(map, "spend")),
      review: parse_review(Map.get(map, "review"))
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, %{}] end)
    |> Map.new()
  end

  @doc "A `match` map as `%{provider: s, family: s, model: s}`, only the keys that parsed."
  @spec parse_match(term()) :: map()
  def parse_match(%{} = match) do
    match = stringify(match)

    for key <- @match_keys,
        value = Map.get(match, key),
        is_binary(value) or is_atom(value),
        value not in [nil, ""],
        into: %{} do
      {String.to_existing_atom(key), to_string(value)}
    end
  end

  def parse_match(_), do: %{}

  @doc "Parse a tier name (atom or string); `nil` when it is not one."
  @spec tier(term()) :: Guardrails.tier() | nil
  def tier(v), do: parse_in(v, Guardrails.tiers())

  @doc "Parse a security mode name."
  @spec mode(term()) :: :bypass | :auto | :strict | nil
  def mode(v), do: parse_in(v, [:bypass, :auto, :strict])

  @doc "Parse an egress level name."
  @spec egress(term()) :: :open | :allowlist | :none | nil
  def egress(v), do: parse_in(v, [:open, :allowlist, :none])

  @doc "Parse a difficulty ceiling, 1..5 (accepts `3` and `\"D3\"`)."
  @spec difficulty(term()) :: 1..5 | nil
  def difficulty(n) when is_integer(n) and n in 1..5, do: n
  def difficulty("D" <> rest), do: difficulty(rest)

  def difficulty(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> difficulty(n)
      _ -> nil
    end
  end

  def difficulty(_), do: nil

  defp parse_in(v, allowed) when is_atom(v) and not is_nil(v), do: if(v in allowed, do: v)

  defp parse_in(v, allowed) when is_binary(v),
    do: Enum.find(allowed, &(Atom.to_string(&1) == v))

  defp parse_in(_, _), do: nil

  defp parse_spend(%{} = spend) do
    spend = stringify(spend)

    [
      action: parse_in(Map.get(spend, "action"), [:park, :page]),
      tokens: pos_int(Map.get(spend, "tokens")),
      wall_clock_s: pos_int(Map.get(spend, "wall_clock_s"))
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_spend(_), do: %{}

  defp parse_review(%{} = review) do
    review = stringify(review)

    [
      cross_family: parse_in(Map.get(review, "cross_family"), [:required, :workspace]),
      same_family_fallback:
        parse_in(Map.get(review, "same_family_fallback"), [:hold, :record, :workspace]),
      min_reviewer_tier:
        parse_in(Map.get(review, "min_reviewer_tier"), [:economy, :standard, :premium])
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_review(_), do: %{}

  defp pos_int(n) when is_integer(n) and n > 0, do: n
  defp pos_int(_), do: nil

  # ---- validation ----------------------------------------------------------

  @doc """
  Validate a `guardrails` block. Returns a list of human-readable errors, `[]`
  when valid. Unknown keys are refused: a typo in a security block must not
  read as "configured".
  """
  @spec validate(term()) :: [String.t()]
  def validate(nil), do: []

  def validate(%{} = block) do
    block = stringify(block)

    unknown(block, @block_keys, "guardrails") ++
      validate_bindings(Map.get(block, "bindings")) ++
      validate_defaults(Map.get(block, "defaults"), "guardrails.defaults") ++
      validate_subjects(Map.get(block, "subjects"), "guardrails.subjects") ++
      validate_repos(Map.get(block, "repos"))
  end

  def validate(_), do: ["guardrails must be a map"]

  defp unknown(map, allowed, label) do
    case Map.keys(map) -- allowed do
      [] -> []
      keys -> ["#{label} has unknown key(s): #{Enum.join(Enum.sort(keys), ", ")}"]
    end
  end

  defp validate_bindings(nil), do: []

  defp validate_bindings(%{} = bindings) do
    Enum.flat_map(bindings, fn {name, binding} ->
      label = "guardrails.bindings.#{name}"

      name_errors =
        if permission_name?(name), do: [], else: ["#{label}: not a valid permission name"]

      name_errors ++
        case binding do
          %{} = b -> validate_binding(stringify(b), label)
          _ -> ["#{label} must be a map"]
        end
    end)
  end

  defp validate_bindings(_), do: ["guardrails.bindings must be a map"]

  defp validate_binding(binding, label) do
    unknown(binding, @binding_keys, label) ++
      enum_error(Map.get(binding, "grant_by"), @grant_by, "#{label}.grant_by") ++
      enum_error(
        Map.get(binding, "min_tier"),
        Enum.map(Guardrails.tiers(), &Atom.to_string/1),
        "#{label}.min_tier"
      ) ++
      bool_error(Map.get(binding, "enforced_read_only"), "#{label}.enforced_read_only") ++
      tunnels_error(Map.get(binding, "tunnels"), "#{label}.tunnels") ++
      grant_hosts_error(Map.get(binding, "hosts"), "#{label}.hosts") ++
      env_map_error(Map.get(binding, "env_from_secret"), "#{label}.env_from_secret") ++
      string_error(Map.get(binding, "ssh_key_secret"), "#{label}.ssh_key_secret") ++
      string_error(Map.get(binding, "token_secret"), "#{label}.token_secret") ++
      env_name_error(Map.get(binding, "token_env"), "#{label}.token_env") ++
      tags_error(Map.get(binding, "tags"), "#{label}.tags")
  end

  # `tags: ["prod"]` makes a `secrets:` binding operator-grant (§5.1).
  defp tags_error(nil, _), do: []

  defp tags_error(list, label) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: [],
      else: ["#{label} must be a list of non-empty strings"]
  end

  defp tags_error(_, label), do: ["#{label} must be a list of non-empty strings"]

  defp validate_defaults(nil, _label), do: []

  defp validate_defaults(%{} = defaults, label) do
    defaults = stringify(defaults)

    unknown(defaults, ["permissions"], label) ++
      case Map.get(defaults, "permissions") do
        nil ->
          []

        list when is_list(list) ->
          # The ticket permission vocabulary (G12), not just a well-formed name:
          # a default that `ResolvePermissions` would drop is refused here.
          for p <- list,
              {:error, why} <- [Permissions.parse(p)],
              do: "#{label}.permissions: #{why}"

        _ ->
          ["#{label}.permissions must be a list of permission names"]
      end
  end

  defp validate_defaults(_, label), do: ["#{label} must be a map"]

  defp validate_subjects(nil, _label), do: []

  defp validate_subjects(list, label) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{} = entry, i} -> validate_cap(stringify(entry), "#{label}[#{i}]")
      {_, i} -> ["#{label}[#{i}] must be a map"]
    end)
  end

  defp validate_subjects(_, label), do: ["#{label} must be a list"]

  defp validate_cap(entry, label) do
    match_errors =
      case Map.get(entry, "match") do
        %{} = m ->
          m = stringify(m)

          if map_size(m) == 0 do
            ["#{label}.match must name at least one of provider, family, model"]
          else
            unknown(m, @match_keys, "#{label}.match") ++
              for(
                {k, v} <- m,
                not (is_binary(v) and v != ""),
                do: "#{label}.match.#{k} must be a non-empty string"
              )
          end

        _ ->
          ["#{label}.match is required and must be a map"]
      end

    unknown(entry, @cap_keys, label) ++
      match_errors ++
      enum_error(
        Map.get(entry, "max_tier"),
        Enum.map(Guardrails.tiers(), &Atom.to_string/1),
        "#{label}.max_tier"
      ) ++
      enum_error(Map.get(entry, "min_mode"), ~w(bypass auto strict), "#{label}.min_mode") ++
      enum_error(Map.get(entry, "egress"), ~w(open allowlist none), "#{label}.egress") ++
      difficulty_error(Map.get(entry, "max_difficulty"), "#{label}.max_difficulty") ++
      validate_spend(Map.get(entry, "spend"), "#{label}.spend") ++
      validate_review(Map.get(entry, "review"), "#{label}.review")
  end

  defp validate_spend(nil, _), do: []

  defp validate_spend(%{} = spend, label) do
    spend = stringify(spend)

    unknown(spend, ~w(action tokens wall_clock_s), label) ++
      enum_error(Map.get(spend, "action"), ~w(park page), "#{label}.action") ++
      pos_int_error(Map.get(spend, "tokens"), "#{label}.tokens") ++
      pos_int_error(Map.get(spend, "wall_clock_s"), "#{label}.wall_clock_s")
  end

  defp validate_spend(_, label), do: ["#{label} must be a map"]

  defp validate_review(nil, _), do: []

  defp validate_review(%{} = review, label) do
    review = stringify(review)

    unknown(review, ~w(cross_family same_family_fallback min_reviewer_tier), label) ++
      enum_error(Map.get(review, "cross_family"), @cross_family, "#{label}.cross_family") ++
      enum_error(
        Map.get(review, "same_family_fallback"),
        @fallbacks,
        "#{label}.same_family_fallback"
      ) ++
      enum_error(
        Map.get(review, "min_reviewer_tier"),
        @reviewer_tiers,
        "#{label}.min_reviewer_tier"
      )
  end

  defp validate_review(_, label), do: ["#{label} must be a map"]

  defp validate_repos(nil), do: []

  defp validate_repos(%{} = repos) do
    Enum.flat_map(repos, fn
      {repo, %{} = entry} ->
        label = "guardrails.repos.#{repo}"
        entry = stringify(entry)

        unknown(entry, @repo_keys, label) ++
          validate_defaults(Map.get(entry, "defaults"), "#{label}.defaults") ++
          validate_subjects(Map.get(entry, "subjects"), "#{label}.subjects")

      {repo, _} ->
        ["guardrails.repos.#{repo} must be a map"]
    end)
  end

  defp validate_repos(_), do: ["guardrails.repos must be a map"]

  defp permission_name?(name) when is_binary(name), do: Regex.match?(@permission_re, name)
  defp permission_name?(_), do: false

  defp enum_error(nil, _, _), do: []

  defp enum_error(v, allowed, label) do
    if is_binary(v) and v in allowed,
      do: [],
      else: ["#{label} must be one of #{Enum.join(allowed, ", ")}"]
  end

  defp difficulty_error(nil, _), do: []

  defp difficulty_error(v, label),
    do: if(difficulty(v), do: [], else: ["#{label} must be 1..5 (or \"D1\"..\"D5\")"])

  defp pos_int_error(nil, _), do: []

  defp pos_int_error(v, label),
    do: if(pos_int(v), do: [], else: ["#{label} must be a positive integer"])

  defp bool_error(nil, _), do: []
  defp bool_error(v, _) when is_boolean(v), do: []
  defp bool_error(_, label), do: ["#{label} must be a boolean"]

  defp string_error(nil, _), do: []
  defp string_error(v, _) when is_binary(v) and v != "", do: []
  defp string_error(_, label), do: ["#{label} must be a non-empty string"]

  # A binding's `hosts` become ticket grants (G14), which never wildcard
  # (`Egress.Policy.normalize_grant/1`): a `*.` entry is a config error here
  # rather than a host that silently matches nothing.
  defp grant_hosts_error(nil, _), do: []

  defp grant_hosts_error(list, label) when is_list(list) do
    for h <- list,
        not (is_binary(h) and match?({:ok, _}, EgressPolicy.normalize_grant(h))),
        do: "#{label}: #{inspect(h)} is not a valid host:port (wildcards are not allowed)"
  end

  defp grant_hosts_error(_, label), do: ["#{label} must be a list of host:port strings"]

  # `HOST:PORT` bridges 127.0.0.1:PORT in the jail; `LOCAL:HOST:PORT` picks the
  # local port (the same shape as `sandbox.egress_tunnels`).
  defp tunnels_error(nil, _), do: []

  defp tunnels_error(list, label) when is_list(list) do
    for t <- list,
        not valid_tunnel?(t),
        do: "#{label}: #{inspect(t)} is not HOST:PORT or LOCAL:HOST:PORT"
  end

  defp tunnels_error(_, label), do: ["#{label} must be a list of tunnel strings"]

  defp valid_tunnel?(t) when is_binary(t) do
    case String.split(t, ":") do
      [host, port] ->
        match?({:ok, _}, EgressPolicy.normalize_grant(host <> ":" <> port))

      [local, host, port] ->
        match?({n, ""} when n in 1..65_535, Integer.parse(local)) and
          match?({:ok, _}, EgressPolicy.normalize_grant(host <> ":" <> port))

      _ ->
        false
    end
  end

  defp valid_tunnel?(_), do: false

  defp env_name_error(nil, _), do: []

  defp env_name_error(name, label) do
    if is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: [],
      else: ["#{label} must be a valid environment variable name"]
  end

  defp env_map_error(nil, _), do: []

  defp env_map_error(%{} = m, label) do
    for {k, v} <- m,
        not (is_binary(k) and is_binary(v) and v != ""),
        do: "#{label}.#{k} must map an env var name to a secret name"
  end

  defp env_map_error(_, label), do: ["#{label} must be a map"]

  # ---- helpers -------------------------------------------------------------

  defp list_of_maps(list) when is_list(list),
    do: for(%{} = m <- list, do: stringify(m))

  defp list_of_maps(_), do: []

  @doc false
  @spec stringify(term()) :: term()
  def stringify(%{__struct__: _} = struct), do: struct

  def stringify(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  def stringify(other), do: other
end
