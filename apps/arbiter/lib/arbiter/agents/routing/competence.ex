defmodule Arbiter.Agents.Routing.Competence do
  @moduledoc """
  The hand competence matrix (bd-biycyw, R6 of
  `docs/design/paced-quota-routing-signals.md` §3.1–3.6): what each model (and
  cell) costs by the time its task merges, including expected attempts, fix
  passes and review rounds.

  ## Keying and the Fallback Ladder (§3.2)

  A candidate's cell is looked up by the fallback ladder, finest first:

    * **Rung 0** — `{provider, model, difficulty, issue_type}`
    * **Rung 1** — `{provider, model, difficulty}`
    * **Rung 2** — `{family, tier, difficulty}`
    * **Rung 3** — the hand prior for `{family, tier}` or `{family}`

  ## Rows and Storage (§3.3)

  Code defaults (`default_rows/0`) supply the baseline measured from the
  2026-08-24 to 2026-10-01 window (§3.6). Operator-owned overrides live on the
  installation singleton (`Arbiter.Settings.competence_matrix/0`) and are
  validated by `normalize_rows/1`; `rows/0` evaluates the override ahead of the
  code defaults.

  ## δ by Side (§3.4)

      δ(implementer pool, c) = (A_k + F_k) × weight(m)
      δ(reviewer pool, c)    = R_k × weight(projected reviewer model)

  Pure: no I/O, no clock.
  """

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Quota
  alias Arbiter.Quota.Headroom
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type row :: %{String.t() => term()}

  @type found :: %{
          rung: 0..3,
          basis: :cell | :model_difficulty | :family_tier_difficulty | :prior,
          n: non_neg_integer(),
          key: tuple(),
          row: row(),
          author_runs: float(),
          review_runs: float(),
          time_h: float(),
          weight: float()
        }

  # Baseline measurements from design §3.6 (2026-08-24 to 2026-10-01 window, cells with n >= 5)
  # Author runs = attempts + fix passes; review runs = review rounds.
  @baseline_rows [
    %{
      "match" => %{
        "provider" => "antigravity",
        "model" => "gemini-3.8-flash-low",
        "difficulty" => 0
      },
      "n" => 11,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 1.0,
      "reviewed_n" => 4,
      "review_rounds" => 0.36,
      "fix_passes" => 0.0,
      "attempts" => 1.36,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 5.1,
      "time_to_close_median_hours" => 0.4,
      "cost_usd_mean" => 0.04,
      "cost_usd_median" => 0.0,
      "author_runs" => 1.36,
      "review_runs" => 0.36,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "haiku", "difficulty" => 0},
      "n" => 14,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.8,
      "reviewed_n" => 10,
      "review_rounds" => 1.07,
      "fix_passes" => 0.21,
      "attempts" => 1.14,
      "difficulty_raised" => 0.14,
      "time_to_close_mean_hours" => 0.3,
      "time_to_close_median_hours" => 0.2,
      "cost_usd_mean" => 0.93,
      "cost_usd_median" => 0.46,
      "author_runs" => 1.35,
      "review_runs" => 1.07,
      "weight" => 1.0
    },
    %{
      "match" => %{
        "provider" => "antigravity",
        "model" => "gemini-3.8-flash-low",
        "difficulty" => 1
      },
      "n" => 13,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.5,
      "reviewed_n" => 8,
      "review_rounds" => 1.69,
      "fix_passes" => 0.46,
      "attempts" => 2.23,
      "difficulty_raised" => 0.15,
      "time_to_close_mean_hours" => 11.0,
      "time_to_close_median_hours" => 1.1,
      "cost_usd_mean" => 2.0,
      "cost_usd_median" => 0.37,
      "author_runs" => 2.69,
      "review_runs" => 1.69,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "haiku", "difficulty" => 1},
      "n" => 80,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.41,
      "reviewed_n" => 79,
      "review_rounds" => 2.27,
      "fix_passes" => 0.78,
      "attempts" => 1.68,
      "difficulty_raised" => 0.18,
      "time_to_close_mean_hours" => 1.4,
      "time_to_close_median_hours" => 0.7,
      "cost_usd_mean" => 2.68,
      "cost_usd_median" => 1.77,
      "author_runs" => 2.46,
      "review_runs" => 2.27,
      "weight" => 1.0
    },
    %{
      "match" => %{
        "provider" => "antigravity",
        "model" => "gemini-3.8-flash-medium",
        "difficulty" => 2
      },
      "n" => 6,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.33,
      "reviewed_n" => 6,
      "review_rounds" => 2.83,
      "fix_passes" => 1.5,
      "attempts" => 2.67,
      "difficulty_raised" => 0.17,
      "time_to_close_mean_hours" => 9.1,
      "time_to_close_median_hours" => 1.8,
      "cost_usd_mean" => 6.93,
      "cost_usd_median" => 6.34,
      "author_runs" => 4.17,
      "review_runs" => 2.83,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-sonnet-5", "difficulty" => 2},
      "n" => 258,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.32,
      "reviewed_n" => 240,
      "review_rounds" => 2.36,
      "fix_passes" => 1.07,
      "attempts" => 1.46,
      "difficulty_raised" => 0.05,
      "time_to_close_mean_hours" => 6.2,
      "time_to_close_median_hours" => 1.2,
      "cost_usd_mean" => 10.57,
      "cost_usd_median" => 7.84,
      "author_runs" => 2.53,
      "review_runs" => 2.36,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-sonnet-5-5", "difficulty" => 2},
      "n" => 38,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.58,
      "reviewed_n" => 36,
      "review_rounds" => 1.66,
      "fix_passes" => 0.58,
      "attempts" => 1.24,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 1.6,
      "time_to_close_median_hours" => 1.1,
      "cost_usd_mean" => 2.75,
      "cost_usd_median" => 2.2,
      "author_runs" => 1.82,
      "review_runs" => 1.66,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-opus-5", "difficulty" => 3},
      "n" => 159,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.45,
      "reviewed_n" => 143,
      "review_rounds" => 1.87,
      "fix_passes" => 0.57,
      "attempts" => 1.55,
      "difficulty_raised" => 0.03,
      "time_to_close_mean_hours" => 8.8,
      "time_to_close_median_hours" => 2.0,
      "cost_usd_mean" => 20.82,
      "cost_usd_median" => 16.81,
      "author_runs" => 2.12,
      "review_runs" => 1.87,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-opus-5-5", "difficulty" => 3},
      "n" => 100,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.84,
      "reviewed_n" => 96,
      "review_rounds" => 1.32,
      "fix_passes" => 0.1,
      "attempts" => 1.51,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 9.0,
      "time_to_close_median_hours" => 2.4,
      "cost_usd_mean" => 10.66,
      "cost_usd_median" => 8.76,
      "author_runs" => 1.61,
      "review_runs" => 1.32,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-sonnet-5-5", "difficulty" => 3},
      "n" => 8,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.88,
      "reviewed_n" => 8,
      "review_rounds" => 1.5,
      "fix_passes" => 0.0,
      "attempts" => 1.88,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 1.8,
      "time_to_close_median_hours" => 1.7,
      "cost_usd_mean" => 5.08,
      "cost_usd_median" => 4.72,
      "author_runs" => 1.88,
      "review_runs" => 1.5,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-opus-5", "difficulty" => 4},
      "n" => 9,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.78,
      "reviewed_n" => 9,
      "review_rounds" => 1.44,
      "fix_passes" => 0.11,
      "attempts" => 1.33,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 24.1,
      "time_to_close_median_hours" => 2.2,
      "cost_usd_mean" => 33.15,
      "cost_usd_median" => 24.72,
      "author_runs" => 1.44,
      "review_runs" => 1.44,
      "weight" => 1.0
    },
    %{
      "match" => %{"provider" => "claude", "model" => "claude-opus-5-5", "difficulty" => 4},
      "n" => 6,
      "rung" => 1,
      "measured_at" => "2026-10-01",
      "round_1_approve" => 0.83,
      "reviewed_n" => 6,
      "review_rounds" => 1.17,
      "fix_passes" => 0.17,
      "attempts" => 1.17,
      "difficulty_raised" => 0.0,
      "time_to_close_mean_hours" => 22.2,
      "time_to_close_median_hours" => 6.4,
      "cost_usd_mean" => 55.3,
      "cost_usd_median" => 31.51,
      "author_runs" => 1.34,
      "review_runs" => 1.17,
      "weight" => 1.0
    }
  ]

  # Fallback priors for unmeasured models/families (§3.2, Rung 3)
  @prior_rows [
    %{
      "match" => %{"family" => "anthropic"},
      "rung" => 3,
      "n" => 0,
      "author_runs" => 2.0,
      "review_runs" => 1.5,
      "time_to_close_median_hours" => 2.0,
      "weight" => 1.0
    },
    %{
      "match" => %{"family" => "google"},
      "rung" => 3,
      "n" => 0,
      "author_runs" => 2.5,
      "review_runs" => 1.5,
      "time_to_close_median_hours" => 3.0,
      "weight" => 1.0
    },
    %{
      "match" => %{"family" => "openai"},
      "rung" => 3,
      "n" => 0,
      "author_runs" => 2.0,
      "review_runs" => 1.5,
      "time_to_close_median_hours" => 2.0,
      "weight" => 1.0
    },
    %{
      "match" => %{},
      "rung" => 3,
      "n" => 0,
      "author_runs" => 2.0,
      "review_runs" => 1.5,
      "time_to_close_median_hours" => 2.0,
      "weight" => 1.0
    }
  ]

  @default_rows @baseline_rows ++ @prior_rows

  @doc "The code-default competence rows (§3.6 baseline and priors)."
  @spec default_rows() :: [row()]
  def default_rows, do: @default_rows

  @doc "The effective rows: the installation override ahead of the code defaults."
  @spec rows() :: [row()]
  def rows, do: (Settings.competence_matrix() || []) ++ @default_rows

  @doc """
  Validate and normalise operator-supplied competence rows.
  """
  @spec normalize_rows(term()) :: {:ok, [row()]} | {:error, String.t()}
  def normalize_rows(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, idx}, {:ok, acc} ->
      case normalize_row(row, idx) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_rows(other),
    do: {:error, "competence_matrix must be a list of maps; got: #{inspect(other)}"}

  defp normalize_row(%{} = row, idx) do
    match = Map.get(row, "match") || Map.get(row, :match)

    if not is_map(match) or match == %{} do
      {:error, "competence_matrix row #{idx}: match must be a non-empty map"}
    else
      normalized_match =
        match
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      normalized =
        row
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.put("match", normalized_match)

      {:ok, normalized}
    end
  end

  defp normalize_row(other, idx),
    do: {:error, "competence_matrix row #{idx}: expected map, got: #{inspect(other)}"}

  @doc """
  Look up the competence cell for a choice by the fallback ladder (§3.2).
  """
  @spec lookup([row()], map()) :: found() | nil
  def lookup(rows, choice) when is_list(rows) and is_map(choice) do
    provider = to_string(choice[:provider] || choice[:agent_type] || "")
    model = choice[:model] && to_string(choice.model)
    difficulty = choice[:difficulty]
    type = choice[:issue_type] && to_string(choice.issue_type)
    %{family: family} = ModelFamily.classify(provider, model)
    tier = choice[:tier] && to_string(choice.tier)

    # Ladder steps:
    # 0: (provider, model, difficulty, issue_type)
    # 1: (provider, model, difficulty)
    # 2: (family, tier, difficulty)
    # 3: (family, tier) or family prior
    rungs = [
      {0, :cell, {provider, model, difficulty, type},
       &match_rung0?(&1, provider, model, difficulty, type)},
      {1, :model_difficulty, {provider, model, difficulty},
       &match_rung1?(&1, provider, model, difficulty)},
      {2, :family_tier_difficulty, {family, tier, difficulty},
       &match_rung2?(&1, family, tier, difficulty)},
      {3, :prior, {family, tier}, &match_rung3?(&1, family, tier)}
    ]

    Enum.find_value(rungs, fn {rung, basis, key, matcher} ->
      case Enum.find(rows, matcher) do
        nil ->
          nil

        %{} = matched_row ->
          build_found(rung, basis, key, matched_row)
      end
    end)
  end

  defp build_found(rung, basis, key, row) do
    attempts = num(row["attempts"], 1.0)
    fix_passes = num(row["fix_passes"], 0.0)
    review_rounds = num(row["review_rounds"], 1.0)

    author_runs = num(row["author_runs"], attempts + fix_passes)
    review_runs = num(row["review_runs"], review_rounds)
    weight = num(row["weight"], 1.0)

    time_h =
      num(
        row["time_to_close_median_hours"] || row["time_to_close_mean_hours"] || row["time_h"],
        0.0
      )

    %{
      rung: rung,
      basis: basis,
      n: Map.get(row, "n", 0),
      key: key,
      row: row,
      author_runs: author_runs,
      review_runs: review_runs,
      time_h: time_h,
      weight: weight
    }
  end

  defp row_rung(%{"rung" => r}) when is_integer(r), do: r

  defp row_rung(%{"match" => m}) do
    cond do
      Map.has_key?(m, "issue_type") and Map.has_key?(m, "model") -> 0
      Map.has_key?(m, "model") and Map.has_key?(m, "difficulty") -> 1
      Map.has_key?(m, "tier") and Map.has_key?(m, "difficulty") -> 2
      true -> 3
    end
  end

  defp row_rung(_), do: 3

  defp match_rung0?(%{"match" => m} = row, p, m_name, d, t) do
    row_rung(row) == 0 and match_val?(m["provider"], p) and match_model?(m["model"], m_name) and
      match_val?(m["difficulty"], d) and match_val?(m["issue_type"], t) and
      not_nil?([d, t, m_name])
  end

  defp match_rung0?(_, _, _, _, _), do: false

  defp match_rung1?(%{"match" => m} = row, p, m_name, d) do
    row_rung(row) == 1 and match_val?(m["provider"], p) and match_model?(m["model"], m_name) and
      match_val?(m["difficulty"], d) and not_nil?([d, m_name])
  end

  defp match_rung1?(_, _, _, _), do: false

  defp match_rung2?(%{"match" => m} = row, fam, tier, d) do
    row_rung(row) == 2 and match_val?(m["family"], fam) and match_val?(m["tier"], tier) and
      match_val?(m["difficulty"], d) and not_nil?([fam, tier, d])
  end

  defp match_rung2?(_, _, _, _), do: false

  defp match_rung3?(%{"match" => m} = row, fam, tier) do
    row_rung(row) == 3 and
      cond do
        m["family"] != nil and m["tier"] != nil ->
          match_val?(m["family"], fam) and match_val?(m["tier"], tier)

        m["family"] != nil ->
          match_val?(m["family"], fam)

        m == %{} ->
          true

        true ->
          false
      end
  end

  defp match_rung3?(_, _, _), do: false

  defp match_val?(nil, _), do: true

  defp match_val?(expected, actual) when is_atom(actual),
    do: match_val?(expected, Atom.to_string(actual))

  defp match_val?(expected, actual), do: to_string(expected) == to_string(actual)

  defp match_model?(nil, _), do: true
  defp match_model?(_pattern, nil), do: false

  defp match_model?(pattern, model) do
    pattern = to_string(pattern)
    model = to_string(model)

    pattern == model or
      "claude-" <> pattern == model or
      pattern == "claude-" <> model or
      glob_match?(pattern, model)
  end

  defp glob_match?(glob, str) do
    pattern =
      glob
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z"), str)
  end

  defp not_nil?(list), do: Enum.all?(list, &(not is_nil(&1)))

  defp num(v, _default) when is_number(v), do: v * 1.0
  defp num(_, default), do: default * 1.0

  @doc "The relative weight for (provider, model), default 1.0."
  @spec model_weight([row()], term(), term()) :: float()
  def model_weight(rows, provider, model) do
    case Enum.find(rows, fn %{"match" => m} ->
           match_val?(m["provider"], provider) and match_model?(m["model"], model) and
             Map.has_key?(m, "model")
         end) do
      %{"weight" => w} when is_number(w) -> w * 1.0
      _ -> 1.0
    end
  end

  @doc """
  Compute the routing estimates (`%{draw:, time_h:, sides:, reviewer_windows:, cell:}`)
  for an implementer candidate entry on `task` (§3.4).
  """
  @spec estimate(Workspace.t() | nil, map(), Issue.t() | nil, keyword()) :: map()
  def estimate(ws, entry, task, opts \\ []) do
    choice = build_choice(entry, task, opts)
    all_rows = rows()

    case lookup(all_rows, choice) do
      nil ->
        %{draw: 1.0, time_h: 0.0}

      found ->
        build_estimate(ws, entry, task, found, all_rows, opts)
    end
  end

  defp build_choice(entry, task, opts) do
    %{
      provider: entry[:agent_type] || (entry.account && entry.account.provider),
      model: entry.model,
      difficulty:
        (task && (Map.get(task, :difficulty_at_dispatch) || Map.get(task, :difficulty))) || 2,
      issue_type: task && Map.get(task, :issue_type),
      family: entry.family,
      tier: entry[:tier] || Keyword.get(opts, :tier)
    }
  end

  defp build_estimate(ws, entry, task, found, all_rows, opts) do
    base = %{
      author_draw: found.author_runs * found.weight,
      review_runs: found.review_runs,
      time_h: found.time_h,
      cell: %{
        "rung" => found.rung,
        "n" => found.n,
        "basis" => to_string(found.basis),
        "key" => inspect(found.key)
      }
    }

    if reviewer_coupling?(ws) do
      project_and_price_review(ws, entry, task, base, all_rows, opts)
    else
      uncoupled_estimate(base)
    end
  end

  defp reviewer_coupling?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "scoring", "reviewer_coupling"]) == true

  defp reviewer_coupling?(_), do: false

  defp uncoupled_estimate(base) do
    %{
      draw: base.author_draw,
      time_h: base.time_h,
      sides: %{author: base.author_draw, review: base.review_runs},
      reviewer_windows: nil,
      cell: base.cell
    }
  end

  defp project_and_price_review(ws, entry, task, base, all_rows, opts) do
    case ReviewerRouting.project(ws, entry.family, Keyword.merge(opts, task: task)) do
      {:ok, sel} ->
        rev_weight = model_weight(all_rows, sel.provider, sel.model)
        review_draw = base.review_runs * rev_weight

        %{
          draw: base.author_draw,
          time_h: base.time_h,
          sides: %{author: base.author_draw, review: review_draw},
          reviewer_windows: resolve_reviewer_windows(sel, entry, opts),
          cell: base.cell
        }

      _ ->
        uncoupled_estimate(base)
    end
  end

  defp resolve_reviewer_windows(sel, entry, opts) do
    # If projected reviewer is the candidate's own account, use entry's windows directly.
    if sel.account_id && entry.account && sel.account_id == entry.account.id do
      Map.get(entry, :windows, [])
    else
      quota_fun = Keyword.get(opts, :quota_fun, &Quota.latest_for_provider(&1.id, &1.provider))
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      account =
        if sel.account_id,
          do: Arbiter.Accounts.Resolver.get(sel.account_id),
          else: nil

      quota = if account, do: quota_fun.(account)
      if account && quota, do: Headroom.windows(account, quota, now: now), else: []
    end
  end
end
