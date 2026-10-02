defmodule Arbiter.Agents.ProviderConstraint do
  @moduledoc """
  A per-ticket provider constraint (bd-13pqcp): which providers may run the
  ticket's **implementer**.

  ## Shape

  `Issue.provider_constraint` is `nil` (no constraint — every ticket today),
  `%{"require" => [type, ...]}` (only those providers) or
  `%{"exclude" => [type, ...]}` (anything but those). One key, never both:
  `require [claude]` already excludes everything else, so a second key could
  only contradict the first, and a single-key map is exactly the
  allow-set / deny-set a guardrails eligibility rule (bd-1e80nw G13) would
  hand routing, so that generalisation can resolve to the same shape.

  Entries are adapter types (`Arbiter.Agents.valid_agent_types/0` — the names
  `arb dispatch --provider` and `arb provider pause` already use). `agy` and
  `antigravity` are accepted as the `gemini` adapter, which is what runs agy;
  note that this means `exclude gemini` also excludes the Gemini CLI itself.

  ## Implementer only — the reviewer is not constrained

  The constraint is about where the ticket's code is *written*. The ReviewGate
  reviewer reads a PR and writes nothing, and the cross-family rule
  (`review_agent.cross_family`, bd-a1ke2c) already requires it to be a
  *different* family from the implementer — constraining it as well would make
  `require claude` forbid every legal reviewer. So `Arbiter.Agents.ReviewerRouting`
  never reads this.

  ## Where it is honoured

  Every path that picks an implementer provider consults it — see the PR for
  the full table. The pieces: `ProviderRouting` drops a violating candidate
  (`provider_constraint`), the legacy resolvers (`Agents.resolve_revision_provider/3`
  and the failover pool in `Worker.Dispatch`) filter, and `check/2` is the
  final gate at every spawn site: a provider that still violates is refused
  with `{:error, {:provider_constraint, provider, phrase}}` rather than run.
  Nothing falls back to an excluded provider; the ticket waits.
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type t :: %{required(String.t()) => [String.t()]}

  @aliases %{"agy" => "gemini", "antigravity" => "gemini"}
  @keys ~w(require exclude)

  # ---- parsing ---------------------------------------------------------------

  @doc """
  Canonicalize user input into the stored shape.

  `{:ok, nil}` for a blank value (clears the constraint), `{:ok, constraint}`
  otherwise, `{:error, message}` for an unknown key or provider, both keys, or
  something that is not a map.
  """
  @spec normalize(term()) :: {:ok, t() | nil} | {:error, String.t()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%{} = raw) do
    entries =
      raw
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.reject(fn {_k, v} -> blank?(v) end)

    with :ok <- check_keys(entries) do
      case entries do
        [] -> {:ok, nil}
        [{key, value}] -> canonical_list(key, value)
      end
    end
  end

  def normalize(_other),
    do: {:error, ~s(provider_constraint must be %{"require" => [...]} or %{"exclude" => [...]})}

  defp check_keys(entries) do
    keys = Enum.map(entries, &elem(&1, 0))

    cond do
      Enum.any?(keys, &(&1 not in @keys)) ->
        {:error,
         "provider_constraint takes only `require` or `exclude`, got: #{Enum.join(keys, ", ")}"}

      length(keys) > 1 ->
        {:error, "provider_constraint takes one of `require` or `exclude`, not both"}

      true ->
        :ok
    end
  end

  defp canonical_list(key, value) do
    names =
      value
      |> List.wrap()
      |> Enum.flat_map(fn
        name when is_binary(name) -> String.split(name, ",", trim: true)
        name when is_atom(name) and not is_nil(name) -> [Atom.to_string(name)]
        other -> [inspect(other)]
      end)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Map.get(@aliases, &1, &1))
      |> Enum.uniq()

    valid = Agents.valid_agent_types()

    case Enum.reject(names, &(&1 in valid)) do
      [] ->
        {:ok, %{key => names}}

      bad ->
        {:error,
         "unknown provider #{Enum.join(bad, ", ")} (valid: #{Enum.join(valid, ", ")}, agy)"}
    end
  end

  defp blank?(nil), do: true
  defp blank?([]), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  # ---- reading ---------------------------------------------------------------

  @doc "The task's constraint, or `nil` when it has none."
  @spec from(Issue.t() | map() | nil) :: t() | nil
  def from(%Issue{provider_constraint: constraint}), do: from(constraint)
  # A board card / issue map (the Snapshot works on plain maps), not a constraint.
  def from(%{provider_constraint: constraint}), do: from(constraint)
  def from(%{"require" => [_ | _]} = constraint), do: constraint
  def from(%{"exclude" => [_ | _]} = constraint), do: constraint
  def from(_), do: nil

  @doc "Whether `provider` (an adapter type or an account provider) may run the implementer."
  @spec allows?(Issue.t() | t() | nil, atom() | String.t() | nil) :: boolean()
  def allows?(subject, provider) do
    case from(subject) do
      nil -> true
      constraint -> allowed?(constraint, adapter_type(provider))
    end
  end

  defp allowed?(%{"require" => list}, type), do: type in list
  defp allowed?(%{"exclude" => list}, type), do: type not in list
  defp allowed?(_other, _type), do: true

  @doc "The providers of `providers` the constraint allows, in order."
  @spec filter(Issue.t() | t() | nil, [atom() | String.t()]) :: [atom() | String.t()]
  def filter(subject, providers) do
    case from(subject) do
      nil -> providers
      constraint -> Enum.filter(providers, &allowed?(constraint, adapter_type(&1)))
    end
  end

  # An account provider (`:antigravity`) runs under its adapter (`gemini`).
  defp adapter_type(provider) when is_atom(provider) and not is_nil(provider) do
    ProviderSettings.agent_type(provider) || Atom.to_string(provider)
  end

  defp adapter_type(provider) when is_binary(provider) do
    provider = String.downcase(provider)
    Map.get(@aliases, provider, provider)
  end

  defp adapter_type(_), do: nil

  # ---- wording ---------------------------------------------------------------

  @doc ~s(`"exclude gemini, codex"` / `"require claude"`.)
  @spec describe(Issue.t() | t() | nil) :: String.t() | nil
  def describe(subject) do
    case from(subject) do
      %{"require" => list} -> "require " <> Enum.join(list, ", ")
      %{"exclude" => list} -> "exclude " <> Enum.join(list, ", ")
      _ -> nil
    end
  end

  @doc "The card / refusal phrase: `held — provider constraint (<detail>)`."
  @spec phrase(String.t()) :: String.t()
  def phrase(detail), do: "held — provider constraint (#{detail})"

  # ---- the gate --------------------------------------------------------------

  @doc """
  The final gate at a spawn site: `:ok`, or
  `{:error, {:provider_constraint, provider, phrase}}` when `provider` is not
  allowed for the task's implementer. `task` may be an `Issue`, a task id, or
  `nil`; an unreadable task is unconstrained (the same fail-open as the other
  dispatch gates — a bug here must not stop the fleet).
  """
  @spec check(Issue.t() | String.t() | nil, atom() | String.t() | nil) ::
          :ok | {:error, {:provider_constraint, atom() | String.t() | nil, String.t()}}
  def check(task_or_id, provider) do
    task = load(task_or_id)

    if allows?(task, provider) do
      :ok
    else
      {:error,
       {:provider_constraint, provider,
        phrase("#{describe(task)}: #{provider || "no provider"} is not allowed")}}
    end
  end

  defp load(%Issue{} = task), do: task

  defp load(id) when is_binary(id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{} = task} -> task
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load(_), do: nil

  # ---- who can take it -------------------------------------------------------

  @doc """
  The one "which provider may take this constrained ticket?" for a fresh
  implementer dispatch and for the board's card: `{:ok, provider}` (the
  adapter type to run) or `{:hold, detail}` — no eligible account has
  capacity. Never an excluded provider; the caller holds the ticket on `:hold`
  and the card reads `held — provider constraint (<detail>)`.

  Under `routing.provider_selection: most_quota` it is `ProviderRouting`'s own
  evaluation (the same candidates, drops and ranking `select/4` uses), with
  the constraint as the first drop reason. Otherwise it is the workspace's
  `agent.type` pool, filtered by the constraint, healthy first
  (`ProviderPool.pick/1`), among the providers whose account still has a free
  slot. A workspace routed by quota with no attached implementer accounts has
  no candidates to evaluate, so it takes the pool path too — it dispatches on
  the pool today.

  An unconstrained ticket is `{:ok, <pool pick>}` with nothing evaluated.
  """
  @spec pick(Workspace.t() | nil, Issue.t() | map(), keyword()) ::
          {:ok, atom()} | {:hold, String.t()}
  def pick(workspace, task, opts \\ []) do
    if routed?(workspace) do
      case ProviderRouting.availability(workspace, task, Keyword.get(opts, :routing_opts, [])) do
        %{available: [best | _]} -> {:ok, String.to_existing_atom(best.agent_type)}
        %{dropped: [_ | _] = dropped} -> {:hold, routed_detail(task, dropped)}
        _no_candidates_at_all -> pick_from_pool(workspace, task)
      end
    else
      pick_from_pool(workspace, task)
    end
  end

  defp routed?(%Workspace{} = workspace), do: ProviderRouting.enabled?(workspace)
  defp routed?(_), do: false

  defp pick_from_pool(workspace, task) do
    pool = Agents.agent_pool(workspace)
    allowed = filter(task, pool)
    with_room = Enum.filter(allowed, &room?(workspace, &1))

    cond do
      allowed == [] ->
        {:hold,
         "#{describe(task)}: no allowed provider in the agent pool (#{Enum.join(pool, ", ")})"}

      with_room == [] ->
        {:hold,
         "#{describe(task)}: no allowed provider has a free slot (#{full(workspace, allowed)})"}

      provider = ProviderPool.pick(with_room) ->
        {:ok, provider}

      true ->
        {:hold,
         "#{describe(task)}: every allowed provider is paused (#{Enum.join(with_room, ", ")})"}
    end
  end

  # An account-less provider has no ceiling; an unreadable one fails open, like
  # every other read of the cap.
  defp room?(workspace, provider) do
    case account_for(workspace, provider) do
      nil -> true
      account -> Concurrency.account_headroom(account, workspace, []) != 0
    end
  rescue
    _ -> true
  end

  defp full(workspace, providers) do
    providers
    |> Enum.map(fn provider ->
      case account_for(workspace, provider) do
        %{provider: p, slug: slug} -> "#{p}:#{slug} at capacity"
        _ -> "#{provider} at capacity"
      end
    end)
    |> Enum.join("; ")
  end

  defp account_for(%Workspace{id: ws_id}, provider), do: Resolver.account(ws_id, provider)
  defp account_for(_, _), do: nil

  # The dropped candidates that the constraint did not itself drop are the ones
  # that explain why nothing allowed is left; with none, the constraint rules
  # out every attached account.
  defp routed_detail(task, dropped) do
    case Enum.reject(dropped, &(&1.reason == "provider_constraint")) do
      [] ->
        "#{describe(task)}: no attached implementer account is allowed"

      others ->
        why =
          Enum.map_join(others, "; ", fn entry ->
            label =
              case entry.account do
                %{provider: p, slug: slug} -> "#{p}:#{slug}"
                _ -> to_string(entry.agent_type)
              end

            reason = entry.reason |> to_string() |> String.replace("_", " ")

            if is_binary(entry.detail),
              do: "#{label} #{reason} (#{entry.detail})",
              else: "#{label} #{reason}"
          end)

        "#{describe(task)}: #{why}"
    end
  end
end
