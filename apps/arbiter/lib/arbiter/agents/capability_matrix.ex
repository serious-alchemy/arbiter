defmodule Arbiter.Agents.CapabilityMatrix do
  @moduledoc """
  The capability matrix (bd-57uzkl, R4 of `docs/design/paced-quota-routing-signals.md`
  §6.2): what each provider (and model) can functionally do, kept apart from
  trust (guardrail profiles) and from write confinement (the adapter's own
  `write_confinement/1`).

  A hard gate, ahead of any weighting. Both routers
  (`Arbiter.Agents.ProviderRouting`, `Arbiter.Agents.ReviewerRouting`) and the
  legacy / explicit dispatch path (`Arbiter.Worker.Dispatch`) ask the same
  `check/4`, so a candidate lacking a required capability is refused the same
  way everywhere, with the drop reason `capability_missing`.

  ## Capabilities

  | Capability | Values | Required by |
  |---|---|---|
  | `resume` | `true` / `false` | the resume roles (`resume_roles/0`) |
  | `async_verification` | `"reliable"` / `"unreliable"` / `"unknown"` | repos declaring `routing.repos.<repo>.requires: ["async_verification"]` |

  `async_verification` is whether the agent survives a long, backgrounded
  verification step (a 5-10 minute test suite) without ending its turn early.
  Only `"reliable"` satisfies a requirement; `"unknown"` — and a capability no
  row states at all — fails closed when required and is ignored otherwise.

  ## Rows

  A row is a string-keyed, JSON-safe map:

      %{"match" => %{"provider" => "antigravity", "model" => "gemini-*"},
        "resume" => true,
        "async_verification" => "unreliable",
        "evidence" => ["bd-40h2to: turn ends while run_command is backgrounded"]}

  `match.provider` is a provider code (`"claude"`, `"antigravity"`, `"codex"`,
  `"gemini"`); the optional `match.model` is a glob (`*` only) that never
  matches an unknown model. Every row that matches a (provider, model) is
  consulted, most specific first (a model glob before a provider-only row, a
  longer glob before a shorter one, the installation override before the code
  defaults at equal specificity), and each capability takes the first row that
  states it. So a narrow row overrides only what it says.

  ## Code defaults and the installation override

  `default_rows/0` is code. The operator's override lives on the installation
  singleton (`Arbiter.Settings.capability_matrix/0`) and is validated by
  `normalize_rows/1`; `rows/0` is the override ahead of the defaults. Nothing
  here is reachable from a worker or the Loop: capability rows are operator-owned
  (design §10).

  ## Switch

  `routing.capability_gates: true` on the workspace (default off). Off means no
  check runs and nothing is recorded (§9 I1); on, it can only remove candidates,
  never add one or loosen a limit. `gate/3` is the one place that reads it.
  """

  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace

  @capabilities ~w(resume async_verification)
  @async_values ~w(reliable unreliable unknown)

  # The roles that continue a prior run rather than start one.
  @resume_roles [:resume, :resume_session, :auto_resume, :reconciler_resume]

  @type row :: %{optional(String.t()) => term()}
  @type gate :: %{rows: [row()], requires: [String.t()]}

  @defaults [
    %{
      "match" => %{"provider" => "antigravity"},
      "resume" => true,
      "async_verification" => "unreliable",
      "evidence" => [
        "bd-b7e33c: splice_prompt/2",
        "bd-40h2to: turn ends while run_command is backgrounded"
      ]
    },
    %{"match" => %{"provider" => "claude"}, "resume" => true, "async_verification" => "reliable"},
    %{"match" => %{"provider" => "codex"}, "resume" => true, "async_verification" => "unknown"}
  ]

  @doc "The capability names a row, a repo's `requires` and a role may mention."
  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @doc "The roles that need the `resume` capability."
  @spec resume_roles() :: [atom()]
  def resume_roles, do: @resume_roles

  @doc "The code-default rows."
  @spec default_rows() :: [row()]
  def default_rows, do: @defaults

  @doc "The effective rows: the installation override, then the code defaults."
  @spec rows() :: [row()]
  def rows, do: (Settings.capability_matrix() || []) ++ @defaults

  @doc """
  Validate and normalise operator-supplied rows (string keys only).

  Every row needs a `match.provider` string; `match.model` is an optional
  string; capability values are `true`/`false` for `resume` and one of
  #{Enum.join(@async_values, ", ")} for `async_verification`; `evidence` is a
  list of strings. Anything else is refused rather than dropped.
  """
  @spec normalize_rows(term()) :: {:ok, [row()]} | {:error, String.t()}
  def normalize_rows(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case normalize_row(row) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, why} -> {:halt, {:error, "capability matrix row #{index}: #{why}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def normalize_rows(_), do: {:error, "the capability matrix must be a list of rows"}

  defp normalize_row(%{} = row) do
    row = Map.new(row, fn {k, v} -> {to_string(k), v} end)
    allowed = ["match", "evidence" | @capabilities]

    with [] <- Map.keys(row) -- allowed,
         {:ok, match} <- normalize_match(Map.get(row, "match")),
         :ok <- validate_values(row),
         :ok <- validate_evidence(Map.get(row, "evidence")) do
      {:ok, row |> Map.take(allowed) |> Map.put("match", match)}
    else
      [_ | _] = unknown -> {:error, "unknown key #{inspect(unknown)}"}
      {:error, _} = error -> error
    end
  end

  defp normalize_row(_), do: {:error, "must be a map"}

  defp normalize_match(%{} = match) do
    match = Map.new(match, fn {k, v} -> {to_string(k), v} end)

    case match do
      %{"provider" => provider} when is_binary(provider) and provider != "" ->
        case Map.get(match, "model") do
          nil ->
            {:ok, %{"provider" => provider}}

          model when is_binary(model) and model != "" ->
            {:ok, %{"provider" => provider, "model" => model}}

          _ ->
            {:error, "match.model must be a non-empty string"}
        end

      _ ->
        {:error, "match.provider must be a non-empty string"}
    end
  end

  defp normalize_match(_), do: {:error, "match.provider must be a non-empty string"}

  defp validate_values(row) do
    cond do
      Map.has_key?(row, "resume") and not is_boolean(row["resume"]) ->
        {:error, "resume must be true or false"}

      Map.has_key?(row, "async_verification") and row["async_verification"] not in @async_values ->
        {:error, "async_verification must be one of #{Enum.join(@async_values, ", ")}"}

      true ->
        :ok
    end
  end

  defp validate_evidence(nil), do: :ok

  defp validate_evidence(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: :ok,
      else: {:error, "evidence must be a list of strings"}
  end

  defp validate_evidence(_), do: {:error, "evidence must be a list of strings"}

  @doc """
  What `rows` say about (`provider`, `model`): `%{capability => {value, row}}`,
  each capability from the most specific matching row that states it.
  """
  @spec resolve([row()], String.t() | nil, String.t() | nil) :: %{String.t() => {term(), row()}}
  def resolve(rows, provider, model) do
    rows
    |> Enum.with_index()
    |> Enum.filter(fn {row, _} -> matches?(row, provider, model) end)
    |> Enum.sort_by(fn {row, index} -> {-specificity(row), index} end)
    |> Enum.reduce(%{}, fn {row, _}, acc ->
      Enum.reduce(@capabilities, acc, fn capability, acc ->
        if Map.has_key?(row, capability),
          do: Map.put_new(acc, capability, {row[capability], row}),
          else: acc
      end)
    end)
  end

  @doc """
  Whether (`provider`, `model`) has every capability in `requires`:
  `:ok`, or `{:missing, capability, detail}` for the first it lacks, the detail
  reading like `needs async_verification; antigravity/gemini-3.8-flash-low:
  unreliable (bd-b7e33c, bd-40h2to)`.
  """
  @spec check([row()], [String.t()], String.t() | nil, String.t() | nil) ::
          :ok | {:missing, String.t(), String.t()}
  def check(rows, requires, provider, model) do
    have = resolve(rows, provider, model)

    Enum.find_value(requires, :ok, fn capability ->
      case Map.get(have, capability) do
        {value, row} ->
          if satisfied?(capability, value),
            do: nil,
            else: {:missing, capability, detail(capability, provider, model, value, row)}

        nil ->
          {:missing, capability, detail(capability, provider, model, "unknown", nil)}
      end
    end)
  end

  defp satisfied?("resume", value), do: value == true
  defp satisfied?("async_verification", value), do: value == "reliable"
  defp satisfied?(_, _), do: false

  defp detail(capability, provider, model, value, row) do
    who = if model, do: "#{provider}/#{model}", else: "#{provider}"
    "needs #{capability}; #{who}: #{value_text(value)}#{evidence_text(row)}"
  end

  defp value_text(true), do: "true"
  defp value_text(false), do: "false"
  defp value_text(value), do: to_string(value)

  defp evidence_text(%{"evidence" => [_ | _] = evidence}) do
    case evidence
         |> Enum.flat_map(&Regex.scan(~r/bd-[0-9a-z]+/, &1))
         |> List.flatten()
         |> Enum.uniq() do
      [] -> ""
      ids -> " (#{Enum.join(ids, ", ")})"
    end
  end

  defp evidence_text(_), do: ""

  defp matches?(%{"match" => %{"provider" => provider} = match}, provider, model) do
    case Map.get(match, "model") do
      nil -> true
      glob -> is_binary(model) and glob_match?(glob, model)
    end
  end

  defp matches?(_row, _provider, _model), do: false

  # A model glob beats a provider-only row; a longer glob beats a shorter one.
  defp specificity(%{"match" => %{"model" => glob}}) when is_binary(glob),
    do: 1_000 + String.length(String.replace(glob, "*", ""))

  defp specificity(_row), do: 0

  defp glob_match?(glob, model) do
    pattern =
      glob
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z"), model)
  end

  # ---- requirements and the switch -----------------------------------------------

  @doc """
  The capabilities a dispatch needs: `resume` for a resume role, then whatever
  the repo declares in `routing.repos.<repo>.requires`.
  """
  @spec requires(atom() | nil, [String.t()]) :: [String.t()]
  def requires(role, repo_requires) do
    role_requires = if role in @resume_roles, do: ["resume"], else: []
    Enum.uniq(role_requires ++ repo_requires)
  end

  @doc "Whether `workspace` has `routing.capability_gates: true`."
  @spec enabled?(Workspace.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "capability_gates"]) == true

  def enabled?(_), do: false

  @doc """
  The gate a routing decision applies, or `nil` when there is nothing to check:
  the switch is off, or neither the `role` nor the `repo` requires anything.
  `nil` is the whole of the off path — callers skip the check on it.
  """
  @spec gate(Workspace.t() | nil, atom() | nil, String.t() | nil) :: gate() | nil
  def gate(workspace, role, repo) do
    with true <- enabled?(workspace),
         [_ | _] = requires <- requires(role, repo_requires(workspace, repo)) do
      %{rows: rows(), requires: requires}
    else
      _ -> nil
    end
  end

  @doc "The `routing.repos.<repo>.requires` list (only known capability names)."
  @spec repo_requires(Workspace.t() | nil, String.t() | nil) :: [String.t()]
  def repo_requires(%Workspace{config: config}, repo) when is_binary(repo) do
    case get_in(config || %{}, ["routing", "repos", repo, "requires"]) do
      list when is_list(list) -> Enum.filter(list, &(&1 in @capabilities))
      _ -> []
    end
  end

  def repo_requires(_workspace, _repo), do: []

  @doc """
  The provider code the matrix is keyed by for an adapter type: the `gemini`
  adapter is `antigravity` when `gemini_code` says it would spawn agy.
  """
  @spec provider_code(atom() | String.t() | nil, String.t() | nil) :: String.t() | nil
  def provider_code(nil, _gemini_code), do: nil

  def provider_code(type, gemini_code) do
    case to_string(type) do
      "gemini" when gemini_code == "antigravity" -> "antigravity"
      other -> other
    end
  end
end
