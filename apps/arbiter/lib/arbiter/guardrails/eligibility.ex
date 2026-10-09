defmodule Arbiter.Guardrails.Eligibility do
  @moduledoc """
  Routing eligibility from guardrails (G13, bd-atll60;
  `docs/design/guardrail-profiles.md` §5.4): may this **subject** take this
  **ticket** in this **role**? A pure yes/no with the reason, so every
  dispatch path — `ProviderRouting`, `ReviewerRouting`, the explicit and
  legacy spawns — asks the one question and records the one answer.

  `evaluate/2` requires, in this order (the first failure is the reason):

    * **`scope`** — the workspace and repo are inside the subject's rule scope;
    * **difficulty** — an implementer's ticket difficulty (`nil` is D2, as
      routing treats it) is at most the profile's `max_difficulty`; a reviewer
      needs the right to review (`max_review_difficulty >= 1`) at that
      difficulty;
    * **action permissions** (implementer roles only) — every *required*
      permission the ticket carries projects under the profile
      (`Arbiter.Guardrails.Projection`: a binding exists, the tier is at or
      above its `min_tier`, the profile lists the kind). A permission marked
      optional (`network?:host`) that is withheld does not make the subject
      ineligible: it is returned in `permission_fallback` (§5.7) for the
      decision record. Reviewers get no action permissions (§5.4);
    * **data classes** (every role) — `phi_data` needs a profile that may see
      it *and* an account with the operator's data agreement
      (`agreements/0`). No account to check is no agreement: fail closed.

  Capability (write confinement / egress under the floored policy) is the
  adapter's answer, asked by the routing layer with the adapter in hand
  (`Arbiter.Guardrails.enforceable/3`), not here.

  ## Unguarded

  With no subject rule configured `Arbiter.Guardrails.effective/4` is `nil`, so
  `evaluate/2` answers `{:ok, %{profile: nil, ...}}` for everything: an install
  that never configures a rule routes exactly as it did before this module
  existed.

  ## Data agreements

  Which accounts may see `phi_data` is contractual, not earned, so it is
  operator-declared installation config
  (`config :arbiter, :guardrail_data_agreements`): a map from data class to the
  `"provider:slug"` labels of the accounts with the agreement.

      config :arbiter, :guardrail_data_agreements, %{"phi_data" => ["claude:default"]}
  """

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Projection

  @type role :: :implementer | :reviewer
  @type attrs :: %{
          required(:provider) => atom() | String.t(),
          required(:model) => String.t() | nil,
          required(:role) => role(),
          optional(:account) => %{provider: atom() | String.t(), slug: String.t()} | nil,
          optional(:difficulty) => integer() | nil,
          optional(:permissions) => [String.t()],
          optional(:workspace) => map() | nil,
          optional(:repo) => String.t() | nil
        }
  @type fallback :: %{permission: String.t(), reason: String.t()}
  @type verdict ::
          {:ok, %{profile: Profile.t() | nil, permission_fallback: [fallback()]}}
          | {:error, String.t()}

  @default_difficulty 2

  @doc """
  The installation's data agreements: `%{data_class => ["provider:slug", ...]}`.
  Empty by default, so a guarded install with `phi_data` tickets and no declared
  agreement routes those tickets nowhere (fail closed).
  """
  @spec agreements() :: %{optional(String.t()) => [String.t()]}
  def agreements do
    case Application.get_env(:arbiter, :guardrail_data_agreements, %{}) do
      %{} = map ->
        Map.new(map, fn {class, accounts} -> {to_string(class), List.wrap(accounts)} end)

      _ ->
        %{}
    end
  end

  @doc """
  May the subject in `attrs` take the ticket? `attrs`: `:provider`, `:model`,
  `:role`, plus `:account` (`%{provider:, slug:}`), `:difficulty`, `:permissions`
  (the ticket's **in-force** permissions, canonical), `:workspace` and `:repo`.

  Options: `:rules` (default `Arbiter.Guardrails.Rules.all/0`) and `:agreements`
  (default `agreements/0`).
  """
  @spec evaluate(attrs(), keyword()) :: verdict()
  def evaluate(%{} = attrs, opts \\ []) do
    subject = Guardrails.subject(attrs.provider, attrs.model)
    workspace = Map.get(attrs, :workspace)

    case Guardrails.effective(
           subject,
           workspace,
           Map.get(attrs, :repo),
           Keyword.take(opts, [:rules])
         ) do
      nil -> {:ok, %{profile: nil, permission_fallback: []}}
      %Profile{} = profile -> judge(profile, attrs, opts)
    end
  end

  defp judge(profile, attrs, opts) do
    permissions = Map.get(attrs, :permissions) || []
    role = attrs.role

    with :ok <- check_scope(profile, attrs),
         :ok <- check_difficulty(profile, role, Map.get(attrs, :difficulty)),
         {:ok, fallback} <- check_actions(profile, role, permissions, attrs),
         :ok <- check_data_classes(profile, permissions, attrs, opts) do
      {:ok, %{profile: profile, permission_fallback: fallback}}
    else
      {:error, why} -> {:error, "#{label(attrs)} (#{profile.tier}): #{why}"}
    end
  end

  # ---- scope ---------------------------------------------------------------------

  defp check_scope(%Profile{in_scope?: true}, _attrs), do: :ok

  defp check_scope(%Profile{}, attrs) do
    where =
      case {workspace_name(Map.get(attrs, :workspace)), Map.get(attrs, :repo)} do
        {nil, nil} -> "this workspace"
        {ws, nil} -> "workspace #{ws}"
        {nil, repo} -> "repo #{repo}"
        {ws, repo} -> "workspace #{ws}, repo #{repo}"
      end

    {:error, "outside its guardrail scope (#{where})"}
  end

  defp workspace_name(%{name: name}) when is_binary(name), do: name
  defp workspace_name(%{prefix: prefix}) when is_binary(prefix), do: prefix
  defp workspace_name(_), do: nil

  # ---- difficulty ----------------------------------------------------------------

  defp check_difficulty(%Profile{} = profile, :implementer, difficulty) do
    d = difficulty || @default_difficulty

    if d <= profile.max_difficulty,
      do: :ok,
      else: {:error, "difficulty D#{d} exceeds its ceiling D#{profile.max_difficulty}"}
  end

  defp check_difficulty(%Profile{max_review_difficulty: 0}, :reviewer, _difficulty),
    do: {:error, "may not review"}

  defp check_difficulty(%Profile{} = profile, :reviewer, difficulty) do
    d = difficulty || @default_difficulty

    if d <= profile.max_review_difficulty,
      do: :ok,
      else:
        {:error,
         "may not review difficulty D#{d} (review ceiling D#{profile.max_review_difficulty})"}
  end

  # ---- action permissions --------------------------------------------------------

  # Reviewers get none (§5.4): nothing to check, nothing withheld.
  defp check_actions(_profile, :reviewer, _permissions, _attrs), do: {:ok, []}

  defp check_actions(profile, :implementer, permissions, attrs) do
    projection =
      Projection.build(permissions,
        profile: profile,
        block: Config.block(Map.get(attrs, :workspace)),
        role: :implementer
      )

    {optional, required} = Enum.split_with(projection.withheld, &optional?(&1.permission))

    case required do
      [] ->
        {:ok, optional}

      [_ | _] ->
        {:error,
         "cannot hold " <>
           Enum.map_join(required, "; ", &"#{required_form(&1.permission)} (#{&1.reason})")}
    end
  end

  defp optional?(canonical) do
    match?({:ok, %{optional?: true}}, Vocabulary.parse(canonical))
  end

  defp required_form(canonical), do: Vocabulary.required_form(canonical)

  # ---- data classes --------------------------------------------------------------

  defp check_data_classes(profile, permissions, attrs, opts) do
    agreements = Keyword.get_lazy(opts, :agreements, &agreements/0)

    permissions
    |> Enum.filter(&Vocabulary.data_class?/1)
    |> Enum.map(&Vocabulary.required_form/1)
    |> Enum.uniq()
    |> Enum.find_value(:ok, fn class ->
      case data_class(profile, class, Map.get(attrs, :account), agreements) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  defp data_class(%Profile{} = profile, class, account, agreements) do
    cond do
      class not in profile.data_classes ->
        {:error, "tier #{profile.tier} may not see #{class}"}

      is_nil(account) ->
        {:error, "no provider account to hold the #{class} data agreement"}

      account_label(account) not in Map.get(agreements, class, []) ->
        {:error, "#{account_label(account)} has no #{class} data agreement"}

      true ->
        :ok
    end
  end

  defp account_label(%{provider: provider, slug: slug}), do: "#{provider}:#{slug}"

  defp label(attrs), do: "#{attrs.provider}/#{attrs.model || "default model"}"
end
