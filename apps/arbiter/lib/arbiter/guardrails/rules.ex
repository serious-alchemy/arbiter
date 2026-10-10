defmodule Arbiter.Guardrails.Rules do
  @moduledoc """
  The installation's ordered subject rules, and matching a subject against them
  (`docs/design/guardrail-profiles.md` §3.1).

  A rule is `%{match: %{provider:, family:, model:}, tier:, scope:, overrides:,
  pinned:, source:}`. It matches a subject when every key it names matches; the
  **most specific** match wins (an exact `model`, then a `model` glob, then
  `family`, then `provider`), ties going to the earlier rule. No match is `nil`, which the caller reads as
  `:quarantine`, the fail-safe default.

  Rules come from two places, DB rules first: the `guardrail_subjects` table
  (`Arbiter.Guardrails.Subjects`, operator-owned) and
  `config :arbiter, :guardrail_subject_rules` (a list of the same shape, for a
  release or a test).
  """

  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Subjects

  @type subject :: %{provider: String.t(), family: String.t() | nil, model: String.t() | nil}
  @type rule :: %{
          match: map(),
          tier: Arbiter.Guardrails.tier(),
          scope: nil | %{String.t() => [String.t()]},
          overrides: map(),
          pinned: boolean(),
          source: atom()
        }

  @doc "Every configured rule: the DB's, in position order, then the app env's."
  @spec all() :: [rule()]
  def all, do: Subjects.rules() ++ env_rules()

  @doc "The rules from `config :arbiter, :guardrail_subject_rules`."
  @spec env_rules() :: [rule()]
  def env_rules do
    :arbiter
    |> Application.get_env(:guardrail_subject_rules, [])
    |> List.wrap()
    |> Enum.flat_map(&normalize(&1, :env))
  end

  @doc "Normalise a rule given with atom or string keys. A rule with no usable tier or match is dropped."
  @spec normalize(term(), atom()) :: [rule()]
  def normalize(raw, source) when is_map(raw) do
    raw = Config.stringify(raw)
    tier = Config.tier(Map.get(raw, "tier"))
    match = Config.parse_match(Map.get(raw, "match"))

    if tier && map_size(match) > 0 do
      [
        %{
          match: match,
          tier: tier,
          scope: parse_scope(Map.get(raw, "scope")),
          overrides: Config.parse_caps(Map.get(raw, "overrides") || %{}),
          pinned: Map.get(raw, "pinned") == true,
          source: source
        }
      ]
    else
      []
    end
  end

  def normalize(_, _), do: []

  defp parse_scope(%{} = scope) when map_size(scope) > 0 do
    Map.new(scope, fn {ws, repos} ->
      {to_string(ws), repos |> List.wrap() |> Enum.map(&to_string/1)}
    end)
  end

  defp parse_scope(_), do: nil

  @doc "The best-matching rule for `subject`, or `nil`."
  @spec match([rule()], subject()) :: rule() | nil
  def match(rules, subject) do
    rules
    |> Enum.filter(&matches?(&1.match, subject))
    |> Enum.with_index()
    |> Enum.max_by(fn {rule, idx} -> {specificity(rule.match), -idx} end, fn -> nil end)
    |> case do
      {rule, _idx} -> rule
      nil -> nil
    end
  end

  @doc "True when every key of `match` matches `subject`."
  @spec matches?(map(), subject()) :: boolean()
  def matches?(match, subject) when is_map(match) and map_size(match) > 0 do
    Enum.all?(match, fn
      {:provider, p} -> provider(p) == provider(subject.provider)
      {:family, f} -> not is_nil(subject.family) and f == subject.family
      {:model, glob} -> is_binary(subject.model) and glob?(glob, subject.model)
    end)
  end

  def matches?(_match, _subject), do: false

  # An exact model (no `*`) outranks any glob: it is the most specific match
  # there is, and it is what `Arbiter.Loop.Trust` writes when it promotes or
  # demotes one subject (G18), so that rule wins over the glob that matched the
  # subject before, wherever it sits in the list.
  defp specificity(match) do
    weight =
      Enum.max(
        Enum.map(match, fn
          {:model, glob} -> if String.contains?(glob, "*"), do: 3, else: 4
          {:family, _} -> 2
          {:provider, _} -> 1
        end)
      )

    {weight, map_size(match)}
  end

  # `agy` is the same harness as `antigravity` (`ModelFamily.classify/2`).
  defp provider("agy"), do: "antigravity"
  defp provider(p), do: p

  @doc "Whether `string` matches the `*` glob `pattern` (the only wildcard)."
  @spec glob?(String.t(), String.t()) :: boolean()
  def glob?(pattern, string) do
    regex =
      pattern
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("^" <> regex <> "$"), string)
  end

  @doc """
  Whether `workspace` and `repo` are inside `scope` (`nil` is "any"). A scope
  key matches the workspace's name, prefix or id; an empty repo list means every
  repo, and a `nil` repo (a single-repo workspace) is inside any entry for the workspace.
  """
  @spec in_scope?(nil | map(), map() | nil, String.t() | nil) :: boolean()
  def in_scope?(nil, _workspace, _repo), do: true

  def in_scope?(scope, workspace, repo) when is_map(scope) do
    keys = workspace_keys(workspace)

    scope
    |> Enum.filter(fn {key, _repos} -> key in keys end)
    |> Enum.any?(fn {_key, repos} ->
      repos == [] or repos == ["*"] or is_nil(repo) or repo in repos
    end)
  end

  defp workspace_keys(%{} = ws),
    do: [Map.get(ws, :name), Map.get(ws, :prefix), Map.get(ws, :id)] |> Enum.filter(&is_binary/1)

  defp workspace_keys(_), do: []
end
