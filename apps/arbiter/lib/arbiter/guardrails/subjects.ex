defmodule Arbiter.Guardrails.Subjects do
  @moduledoc """
  Ash domain and API for the installation's subject rules (`guardrail_subjects`,
  G11).

  Reads are resilient, as `Arbiter.Settings`' are: any DB error, a not-yet-
  migrated install included, reads as "no rules", which is "guardrails off".
  Writes take an authority (`Arbiter.Guardrails.Authority`): the operator may do
  anything, the coordinator may only tighten (demote, narrow a scope, tighten an
  override, pin), and everyone else nothing. A refused write is
  `{:error, {:operator_only, message}}`.
  """

  use Ash.Domain

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Guardrails.Subject

  require Ash.Query

  resources do
    resource Subject
  end

  @doc "Every row, in position order. `[]` on any DB error."
  @spec list() :: [Subject.t()]
  def list do
    Subject
    |> Ash.Query.sort(position: :asc, inserted_at: :asc)
    |> Ash.read!()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "The rows as `Arbiter.Guardrails.Rules` rule maps."
  @spec rules() :: [Rules.rule()]
  def rules, do: Enum.flat_map(list(), &to_rule/1)

  @doc "One row as a rule map (`[]` if it has no usable match)."
  @spec to_rule(Subject.t()) :: [Rules.rule()]
  def to_rule(%Subject{} = s) do
    Rules.normalize(
      %{
        "match" => %{"provider" => s.provider, "family" => s.family, "model" => s.model},
        "tier" => s.tier,
        "scope" => s.scope,
        "overrides" => s.overrides,
        "pinned" => s.pinned
      },
      :db
    )
  end

  @doc """
  Create a rule, or update the one with the same match. `attrs` takes `provider`,
  `family`, `model` (the match), `tier`, `scope`, `overrides`, `pinned`,
  `position`, `reason`.
  """
  @spec put(map(), Authority.authority(), keyword()) ::
          {:ok, Subject.t()} | {:error, term()}
  def put(attrs, authority, opts \\ []) do
    attrs = atomize(attrs)
    existing = find(attrs)
    new_rule = rule_for(attrs, existing)

    with :ok <- authorize(existing && hd_rule(existing), new_rule, authority) do
      attrs = Map.put(attrs, :updated_by, Keyword.get(opts, :actor) || to_string(authority))

      case existing do
        nil -> Ash.create(Subject, attrs, action: :create)
        row -> Ash.update(row, attrs, action: :update)
      end
    end
  end

  @doc "Delete the rule with this match. Operator-only unless the rule was already quarantine."
  @spec delete(map(), Authority.authority()) :: :ok | {:error, term()}
  def delete(match, authority) do
    case find(atomize(match)) do
      nil ->
        :ok

      row ->
        with :ok <- authorize(hd_rule(row), nil, authority), do: Ash.destroy(row)
    end
  end

  defp authorize(old, new, authority) do
    case Authority.authorize(Authority.rule_loosenings(old, new), authority) do
      :ok -> :ok
      {:error, message} -> {:error, {:operator_only, message}}
    end
  end

  defp hd_rule(row) do
    case to_rule(row) do
      [rule | _] -> rule
      [] -> nil
    end
  end

  defp rule_for(attrs, existing) do
    base = (existing && hd_rule(existing)) || %{}

    raw = %{
      "match" => Map.take(attrs, [:provider, :family, :model]),
      "tier" => Map.get(attrs, :tier) || Map.get(base, :tier),
      "scope" => Map.get(attrs, :scope, Map.get(base, :scope)),
      "overrides" => Map.get(attrs, :overrides, Map.get(base, :overrides)),
      "pinned" => Map.get(attrs, :pinned, Map.get(base, :pinned, false))
    }

    case Rules.normalize(raw, :db) do
      [rule] -> rule
      [] -> %{tier: :quarantine, scope: nil, overrides: %{}, pinned: false}
    end
  end

  defp find(attrs) do
    key = Map.take(attrs, [:provider, :family, :model])

    Enum.find(list(), fn s ->
      s |> Map.take([:provider, :family, :model]) |> drop_nil() == drop_nil(key)
    end)
  end

  defp drop_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  @fields ~w(position provider family model tier scope overrides pinned reason updated_by)a

  # Only the known fields, whatever the key type the caller used.
  defp atomize(map) do
    strings = map |> Map.new(fn {k, v} -> {to_string(k), v} end)

    attrs =
      for field <- @fields, Map.has_key?(strings, Atom.to_string(field)), into: %{} do
        {field, Map.fetch!(strings, Atom.to_string(field))}
      end

    if Map.has_key?(attrs, :tier),
      do: Map.update!(attrs, :tier, &(Config.tier(&1) || &1)),
      else: attrs
  end
end
