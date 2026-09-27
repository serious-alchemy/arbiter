defmodule Arbiter.Usage.SummarizeOracle do
  @moduledoc """
  Test oracle for `Arbiter.Usage.summarize/1`: a verbatim copy of its
  implementation before bd-5cevwg — a full-row `Ash.read!` of `usage_events`
  (`raw` included), grouped and summed in Elixir. The slim projection that
  replaced it must return exactly the same rollups, and
  `Arbiter.Usage.SummarizeProjectionTest` asserts that it does.

  Do not "fix" this module: its only job is to be the old behaviour.
  """

  alias Arbiter.Tasks.Dependency
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  def summarize(opts) when is_list(opts) do
    with {:ok, by} <- fetch_by(opts) do
      events =
        Event
        |> base_filter(opts)
        |> Ash.read!()

      {:ok,
       events
       |> group_events(by)
       |> Enum.map(&aggregate_group(by, &1))
       |> sort_rollups(by)
       |> maybe_limit(opts)}
    end
  end

  defp fetch_by(opts) do
    case Keyword.fetch(opts, :by) do
      {:ok, by} ->
        norm = Usage.normalize_by(by)

        if norm in Usage.valid_groupings(),
          do: {:ok, norm},
          else: {:error, {:invalid_grouping, by}}

      :error ->
        {:error, :missing_grouping}
    end
  end

  defp base_filter(query, opts) do
    query
    |> filter_since(Keyword.get(opts, :since))
    |> filter_until(Keyword.get(opts, :until))
    |> filter_workspace_id(Keyword.get(opts, :workspace_id))
    |> filter_provider_account_id(Keyword.get(opts, :provider_account_id))
    |> filter_session_ids(Keyword.get(opts, :session_ids))
  end

  defp filter_since(query, nil), do: query
  defp filter_since(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at >= ^dt)

  defp filter_until(query, nil), do: query
  defp filter_until(query, %DateTime{} = dt), do: Ash.Query.filter(query, occurred_at <= ^dt)

  defp filter_workspace_id(query, nil), do: query
  defp filter_workspace_id(query, ""), do: query
  defp filter_workspace_id(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_provider_account_id(query, nil), do: query
  defp filter_provider_account_id(query, ""), do: query

  defp filter_provider_account_id(query, account_id),
    do: Ash.Query.filter(query, provider_account_id == ^account_id)

  defp filter_session_ids(query, nil), do: query
  defp filter_session_ids(query, []), do: query

  defp filter_session_ids(query, ids) when is_list(ids),
    do: Ash.Query.filter(query, session_id in ^ids)

  defp group_events(events, :day) do
    Enum.group_by(events, fn ev -> Date.to_iso8601(DateTime.to_date(ev.occurred_at)) end)
  end

  defp group_events(events, :task) do
    events
    |> Enum.filter(&task_attributed?/1)
    |> Enum.group_by(& &1.task_id)
  end

  defp group_events(events, :source),
    do: Enum.group_by(events, &Atom.to_string(&1.source || :task))

  defp group_events(events, :session) do
    events
    |> Enum.filter(&session_attributed?/1)
    |> Enum.group_by(& &1.session_id)
  end

  defp group_events(events, :workspace),
    do: Enum.group_by(events, &(&1.workspace_id || "(none)"))

  defp group_events(events, :provider_account) do
    Enum.group_by(events, &(&1.provider_account_id || "(none)"))
  end

  defp group_events(events, :repo), do: Enum.group_by(events, &(&1.repo || "(none)"))
  defp group_events(events, :model), do: Enum.group_by(events, &(&1.model || "(unknown)"))
  defp group_events(events, :provider), do: Enum.group_by(events, &(&1.provider || "(unknown)"))
  defp group_events(events, :step), do: Enum.group_by(events, &Atom.to_string(&1.step))

  defp group_events(events, :epic) do
    parents = load_parent_edges(events)

    Enum.reduce(events, %{}, fn ev, acc ->
      base_task = Usage.base_task_id(ev.task_id)

      case Map.get(parents, base_task, []) do
        [] -> Map.update(acc, "(no_epic)", [ev], &[ev | &1])
        ids -> Enum.reduce(ids, acc, fn pid, a -> Map.update(a, pid, [ev], &[ev | &1]) end)
      end
    end)
  end

  defp task_attributed?(ev), do: is_binary(ev.task_id) and ev.task_id != ""
  defp session_attributed?(ev), do: is_binary(ev.session_id) and ev.session_id != ""

  defp load_parent_edges(events) do
    parent_of = :parent_of

    task_ids =
      events
      |> Enum.map(&Usage.base_task_id(&1.task_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case task_ids do
      [] ->
        %{}

      ids ->
        Dependency
        |> Ash.Query.filter(type == ^parent_of and to_issue_id in ^ids)
        |> Ash.read!()
        |> Enum.reduce(%{}, fn d, acc ->
          Map.update(acc, d.to_issue_id, [d.from_issue_id], &[d.from_issue_id | &1])
        end)
    end
  rescue
    _ -> %{}
  end

  defp aggregate_group(_by, {group, events}) do
    init = %{
      group: group,
      rows: 0,
      total_cost_usd: 0.0,
      cost_known: false,
      tokens_in: 0,
      tokens_out: 0,
      thinking_tokens: 0,
      cache_creation_tokens: 0,
      cache_read_tokens: 0,
      duration_ms: 0,
      estimated: false
    }

    Enum.reduce(events, init, &merge_event/2)
  end

  defp merge_event(ev, acc) do
    %{
      acc
      | rows: acc.rows + 1,
        total_cost_usd: add(acc.total_cost_usd, ev.cost_usd),
        cost_known: acc.cost_known || known?(ev.cost_usd),
        tokens_in: add(acc.tokens_in, ev.tokens_in),
        tokens_out: add(acc.tokens_out, ev.tokens_out),
        thinking_tokens: add(acc.thinking_tokens, ev.thinking_tokens),
        cache_creation_tokens: add(acc.cache_creation_tokens, ev.cache_creation_tokens),
        cache_read_tokens: add(acc.cache_read_tokens, ev.cache_read_tokens),
        duration_ms: add(acc.duration_ms, ev.duration_ms),
        estimated: acc.estimated || estimated_event?(ev)
    }
  end

  defp add(total, nil), do: total
  defp add(total, n), do: total + n

  defp known?(nil), do: false
  defp known?(_), do: true

  defp estimated_event?(%{raw: %{"arb_usage_source" => %{"cost_source" => "estimated"}}}),
    do: true

  defp estimated_event?(_ev), do: false

  defp sort_rollups(rollups, :day), do: Enum.sort_by(rollups, & &1.group)

  defp sort_rollups(rollups, _by),
    do: Enum.sort_by(rollups, &(-(&1.total_cost_usd || 0.0)))

  defp maybe_limit(rollups, opts) do
    case Keyword.get(opts, :limit) do
      n when is_integer(n) and n > 0 -> Enum.take(rollups, n)
      _ -> rollups
    end
  end
end
