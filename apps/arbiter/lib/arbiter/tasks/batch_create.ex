defmodule Arbiter.Tasks.BatchCreate do
  @moduledoc """
  Batch ticket create: many tickets plus all their edges in **one atomic
  write**. The shared core behind `POST /api/issues/batch`, the MCP
  `ticket_create_batch` tool and `arb ticket create --from-file` / `--stdin`.

  Filing an epic with children and edges used to be N creates plus M `dep_add`s,
  racy against Autopilot (which can claim a ticket seconds after promotion). A
  batch writes the whole graph first and — with `promote: true` — only then
  promotes.

  ## Entries

  Each entry is the same shape as a single `ticket_create` plus:

    * `ref` — a batch-local name (`[A-Za-z0-9._:-]`, ≤ 64 chars, unique in the
      batch, and not the id of an existing ticket).
    * `parent_id`, `depends_on` (alias `deps`), `blocks` — each id is **either**
      a `ref` of another entry in this batch **or** the id of an existing
      ticket. A ref is resolved first; forward references are fine.

  Edge direction matches a single create: `depends_on: [x]` is an `x blocks
  <new>` edge, `blocks: [x]` is `<new> blocks x`, `parent_id: p` is `p parent_of
  <new>`.

  ## Atomicity

  Everything that can be checked without writing is checked first (shape, size
  cap, refs, parent-ref cycles, that every existing endpoint exists and is in the
  batch's workspace, duplicate titles). Then the tickets and every edge are
  written in a single transaction; a cycle (including one through existing
  tickets), a bad repo, an Ash validation failure — anything — rolls the whole
  batch back. The error names the failing entry (`tickets[i]`, its `ref` and
  title) and is `{kind, message, %{index:, ref:, title:}}`.

  The tracker mirror (`CreateUpstream`) is deliberately **not** inside the
  transaction: tickets are created with `skip_upstream_create: true` and
  mirrored after the commit, so a rolled-back batch never leaves orphaned
  upstream issues. A mirror failure is reported on that ticket
  (`failures`); the ticket exists.

  ## Result

      {:ok, %{tickets: [%{index:, ref:, issue:, warnings:, failures:}],
              refs: %{ref => id}, edges: [%{from:, to:, type:}],
              promote: nil | %{results: [...], counts: %{...}}}}

  `promote` (option `promote: true`) runs after the commit, over every created
  ticket in entry order, with the per-id contract of `Arbiter.Tasks.BulkResult`:
  one refused promote does not undo the batch or stop the others.

  ## Options

    * `:workspace_id` (required), `:created_by`, `:context` — as for
      `Arbiter.Tasks.Create`.
    * `:force` — skip the duplicate-title check for every entry (an entry's own
      `force` does so for itself).
    * `:promote` — promote after the commit (default `false`).
    * `:promoter` — `(Issue.t() -> {:ok, term} | {:error, term})`, default
      `promote_to_ready`. The surface passes a serializing one; tests use it to
      observe the graph at promote time.
    * `:edge_writer` — `(from, to, type, opts -> result)`, default
      `Arbiter.Tasks.Dependencies.add/4`.
  """

  alias Arbiter.Repo
  alias Arbiter.Tasks.BulkResult
  alias Arbiter.Tasks.Create
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream

  @max_batch 100
  @max_edges 500
  @ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,63}\z/
  @batch_keys ~w(ref depends_on deps blocks force parent_id)

  @type entry :: %{
          index: non_neg_integer(),
          ref: String.t() | nil,
          attrs: map(),
          parent: String.t() | nil,
          depends_on: [String.t()],
          blocks: [String.t()],
          force: boolean()
        }

  @type error :: {atom(), String.t(), map()}

  @doc "Largest number of tickets one batch accepts."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc "Largest total number of edges (parent, depends_on, blocks) one batch accepts."
  @spec max_edges() :: pos_integer()
  def max_edges, do: @max_edges

  # ---- parse ----------------------------------------------------------------

  @doc """
  Turn the raw `tickets` list into entries. `prep` is the surface's per-entry
  attribute preparation (`attrs -> {:ok, attrs} | {:error, reason}`: REST's
  field gate and atom coercion, MCP's typed collection); it receives the entry
  with the batch keys (`ref`, `depends_on`, `deps`, `blocks`, `force`,
  `parent_id`) already taken out.
  """
  @spec parse(term(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [entry()]} | {:error, error()}
  def parse(raw, prep) when is_list(raw) and is_function(prep, 1) do
    cond do
      raw == [] ->
        {:error, {:invalid_request, "`tickets` must be a non-empty array", %{}}}

      length(raw) > @max_batch ->
        {:error,
         {:invalid_request,
          "too many tickets: a batch takes at most #{@max_batch}, got #{length(raw)}", %{}}}

      true ->
        raw
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
          case parse_entry(item, i, prep) do
            {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, entries} -> entries |> Enum.reverse() |> check_edge_total()
          err -> err
        end
    end
  end

  def parse(_raw, _prep),
    do: {:error, {:invalid_request, "`tickets` must be a non-empty array", %{}}}

  defp check_edge_total(entries) do
    total =
      Enum.sum(for e <- entries, do: length(e.depends_on) + length(e.blocks) + parent_count(e))

    if total > @max_edges,
      do:
        {:error,
         {:invalid_request, "too many edges: a batch takes at most #{@max_edges}, got #{total}",
          %{}}},
      else: {:ok, entries}
  end

  defp parent_count(%{parent: nil}), do: 0
  defp parent_count(_), do: 1

  defp parse_entry(%{} = item, i, prep) do
    item = stringify(item)
    title = if is_binary(item["title"]), do: item["title"]

    with {:ok, ref} <- fetch_ref(item),
         {:ok, parent} <- fetch_parent(item),
         {:ok, depends_on} <- fetch_ids(item, ["depends_on", "deps"]),
         {:ok, blocks} <- fetch_ids(item, ["blocks"]),
         {:ok, force} <- fetch_force(item),
         {:ok, attrs} <- prep.(Map.drop(item, @batch_keys)) do
      {:ok,
       %{
         index: i,
         ref: ref,
         attrs: attrs,
         parent: parent,
         depends_on: depends_on,
         blocks: blocks,
         force: force
       }}
    else
      {:error, reason} ->
        {kind, message} = reason_parts(reason)
        error(kind, %{index: i, ref: item["ref"], title: title}, message)
    end
  end

  defp parse_entry(_item, i, _prep),
    do: error(:invalid_request, %{index: i, ref: nil, title: nil}, "must be an object")

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp fetch_ref(%{"ref" => nil}), do: {:ok, nil}
  defp fetch_ref(%{"ref" => ""}), do: {:ok, nil}

  defp fetch_ref(%{"ref" => ref}) when is_binary(ref) do
    if Regex.match?(@ref_pattern, ref),
      do: {:ok, ref},
      else:
        {:error,
         {:invalid_request,
          "ref #{inspect(ref)} is not valid (letters, digits and . _ : -, at most 64 characters)"}}
  end

  defp fetch_ref(%{"ref" => _}), do: {:error, {:invalid_request, "`ref` must be a string"}}
  defp fetch_ref(_), do: {:ok, nil}

  defp fetch_parent(%{"parent_id" => id}) when is_binary(id) do
    if String.trim(id) == "", do: {:ok, nil}, else: {:ok, String.trim(id)}
  end

  defp fetch_parent(%{"parent_id" => nil}), do: {:ok, nil}

  defp fetch_parent(%{"parent_id" => _}),
    do: {:error, {:invalid_request, "`parent_id` must be a string"}}

  defp fetch_parent(_), do: {:ok, nil}

  defp fetch_ids(item, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.get(item, key) do
        nil ->
          {:cont, {:ok, acc}}

        ids when is_list(ids) ->
          if Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")),
            do: {:cont, {:ok, acc ++ Enum.map(ids, &String.trim/1)}},
            else:
              {:halt,
               {:error, {:invalid_request, "`#{key}` must be an array of ticket ids or refs"}}}

        _ ->
          {:halt, {:error, {:invalid_request, "`#{key}` must be an array of ticket ids or refs"}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      err -> err
    end
  end

  defp fetch_force(%{"force" => v}) when v in [true, "true"], do: {:ok, true}
  defp fetch_force(%{"force" => v}) when v in [false, "false", nil], do: {:ok, false}
  defp fetch_force(%{"force" => _}), do: {:error, {:invalid_request, "`force` must be a boolean"}}
  defp fetch_force(_), do: {:ok, false}

  # ---- run ------------------------------------------------------------------

  @spec run([entry()], keyword()) :: {:ok, map()} | {:error, error()}
  def run(entries, opts) when is_list(entries) do
    ws_id = Keyword.fetch!(opts, :workspace_id)

    with {:ok, refs} <- index_refs(entries),
         {:ok, entries} <- resolve(entries, refs, ws_id),
         {:ok, ordered} <- creation_order(entries),
         :ok <- check_duplicates(entries, ws_id, opts),
         {:ok, written} <- write(entries, ordered, ws_id, opts) do
      finish(entries, written, opts)
    end
  end

  # -- refs

  defp index_refs(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn e, {:ok, acc} ->
      cond do
        is_nil(e.ref) ->
          {:cont, {:ok, acc}}

        Map.has_key?(acc, e.ref) ->
          {:halt,
           error(
             :invalid,
             e,
             "duplicate ref #{inspect(e.ref)} (first used by tickets[#{acc[e.ref]}])"
           )}

        match?({:ok, %Issue{}}, Ash.get(Issue, e.ref)) ->
          {:halt,
           error(
             :invalid,
             e,
             "ref #{inspect(e.ref)} collides with the id of an existing ticket; pick another ref"
           )}

        true ->
          {:cont, {:ok, Map.put(acc, e.ref, e.index)}}
      end
    end)
  end

  # Replace every id with `{:ref, ref}` or `{:id, id}` and vet the existing ones.
  defp resolve(entries, refs, ws_id) do
    entries
    |> Enum.reduce_while({:ok, [], %{}}, fn e, {:ok, acc, seen} ->
      with :ok <- check_self(e),
           {:ok, parent, seen} <- resolve_one(e.parent, e, refs, ws_id, seen),
           {:ok, deps, seen} <- resolve_many(e.depends_on, e, refs, ws_id, seen),
           {:ok, blocks, seen} <- resolve_many(e.blocks, e, refs, ws_id, seen) do
        {:cont, {:ok, [%{e | parent: parent, depends_on: deps, blocks: blocks} | acc], seen}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc, _seen} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp check_self(%{ref: nil}), do: :ok

  defp check_self(e) do
    if e.ref in ([e.parent | e.depends_on] ++ e.blocks),
      do: error(:invalid, e, "references itself (ref #{inspect(e.ref)})"),
      else: :ok
  end

  defp resolve_one(nil, _e, _refs, _ws_id, seen), do: {:ok, nil, seen}
  defp resolve_one(id, e, refs, ws_id, seen), do: resolve_id(id, e, refs, ws_id, seen)

  defp resolve_many(ids, e, refs, ws_id, seen) do
    Enum.reduce_while(ids, {:ok, [], seen}, fn id, {:ok, acc, seen} ->
      case resolve_id(id, e, refs, ws_id, seen) do
        {:ok, r, seen} -> {:cont, {:ok, acc ++ [r], seen}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_id(id, e, refs, ws_id, seen) do
    if Map.has_key?(refs, id) do
      {:ok, {:ref, id}, seen}
    else
      case check_existing(id, ws_id, seen) do
        {:ok, seen} -> {:ok, {:id, id}, seen}
        {kind, message} -> error(kind, e, message)
      end
    end
  end

  defp check_existing(id, ws_id, seen) do
    case Map.fetch(seen, id) do
      {:ok, :ok} ->
        {:ok, seen}

      :error ->
        case Ash.get(Issue, id) do
          {:ok, %Issue{workspace_id: ^ws_id}} ->
            {:ok, Map.put(seen, id, :ok)}

          {:ok, %Issue{}} ->
            {:invalid,
             "#{id} is in a different workspace than the batch — relationships are within a single workspace"}

          _ ->
            {:not_found, "#{id} is neither a ref in this batch nor an existing ticket"}
        end
    end
  end

  # -- creation order: a ref'd parent is created before its children

  defp creation_order(entries) do
    place(entries, MapSet.new(), [])
  end

  defp place([], _placed, acc), do: {:ok, Enum.reverse(acc)}

  defp place(remaining, placed, acc) do
    {ready, blocked} =
      Enum.split_with(remaining, fn e ->
        match?(nil, e.parent) or match?({:id, _}, e.parent) or
          MapSet.member?(placed, elem(e.parent, 1))
      end)

    case ready do
      [] ->
        [first | _] = blocked
        chain = Enum.map_join(blocked, " → ", &(&1.ref || "tickets[#{&1.index}]"))
        error(:invalid, first, "parent_id refs form a cycle (#{chain})")

      _ ->
        placed =
          Enum.reduce(ready, placed, fn e, set ->
            if e.ref, do: MapSet.put(set, e.ref), else: set
          end)

        place(blocked, placed, Enum.reverse(ready) ++ acc)
    end
  end

  # -- duplicate titles

  defp check_duplicates(entries, ws_id, opts) do
    batch_force? = Keyword.get(opts, :force, false) == true

    entries
    |> Enum.reduce_while({:ok, %{}}, fn e, {:ok, titles} ->
      force? = batch_force? or e.force

      case duplicate(e, ws_id, force?, titles) do
        :ok -> {:cont, {:ok, remember_title(titles, e)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp remember_title(titles, e) do
    case e.attrs["title"] do
      t when is_binary(t) -> Map.put_new(titles, norm(t), e.index)
      _ -> titles
    end
  end

  defp duplicate(_e, _ws_id, true, _titles), do: :ok

  defp duplicate(e, ws_id, false, titles) do
    attrs = dedup_attrs(e, ws_id)
    title = e.attrs["title"]

    if is_binary(title) and Map.has_key?(titles, norm(title)) do
      error(
        :conflict,
        e,
        "a ticket with this title is already in the batch (tickets[#{titles[norm(title)]}]); " <>
          "set `force: true` on this entry to file it anyway"
      )
    else
      case Create.check_duplicate(attrs, false) do
        :ok -> :ok
        {:duplicate, dup} -> duplicate_error(e, dup)
      end
    end
  end

  defp dedup_attrs(e, ws_id) do
    attrs = Map.put(e.attrs, "workspace_id", ws_id)

    case e.parent do
      nil -> attrs
      {_, id} -> Map.put(attrs, "parent_id", id)
    end
  end

  defp duplicate_error(e, {:local_dup, matches}) do
    ids = Enum.map_join(matches, ", ", & &1.id)

    error(
      :conflict,
      e,
      "an open ticket with this title already exists (#{ids}); set `force: true` on this entry to file it anyway",
      %{matches: Enum.map(matches, &%{id: &1.id, title: &1.title, state: to_string(&1.state)})}
    )
  end

  defp duplicate_error(e, {:tracker_dup, matches}) do
    urls = Enum.map_join(matches, ", ", &(Map.get(&1, :url) || Map.get(&1, :ref) || "?"))

    error(
      :conflict,
      e,
      "an open tracker issue with this title already exists (#{urls}); set `force: true` on this entry to file it anyway",
      %{matches: Enum.map(matches, &%{ref: &1[:ref], title: &1[:title], url: &1[:url]})}
    )
  end

  defp norm(title), do: title |> String.downcase() |> String.trim()

  # -- the write

  # `created` is `%{by_index: %{index => Issue}, by_ref: %{ref => id}}`.
  defp write(entries, ordered, ws_id, opts) do
    result =
      Repo.transaction(fn ->
        created =
          Enum.reduce(ordered, %{by_index: %{}, by_ref: %{}}, &create_one(&1, &2, ws_id, opts))

        Enum.each(entries, &write_edges(&1, created, opts))
        created
      end)

    case result do
      {:ok, created} -> {:ok, created}
      {:error, {:entry_failed, e, kind, message}} -> error(kind, e, message)
    end
  end

  defp create_one(e, created, ws_id, opts) do
    attrs =
      e.attrs
      |> Map.put("workspace_id", ws_id)
      |> Map.put("skip_upstream_create", true)
      |> put_parent(e.parent, created)

    case Ash.create(Issue, attrs, context: Keyword.get(opts, :context, %{})) do
      {:ok, issue} ->
        %{
          by_index: Map.put(created.by_index, e.index, issue),
          by_ref: if(e.ref, do: Map.put(created.by_ref, e.ref, issue.id), else: created.by_ref)
        }

      {:error, err} ->
        Repo.rollback({:entry_failed, e, :invalid, describe(err)})
    end
  end

  defp put_parent(attrs, nil, _created), do: attrs
  defp put_parent(attrs, {:id, id}, _created), do: Map.put(attrs, "parent_id", id)

  defp put_parent(attrs, {:ref, ref}, created),
    do: Map.put(attrs, "parent_id", created.by_ref[ref])

  defp write_edges(e, created, opts) do
    me = Map.fetch!(created.by_index, e.index).id

    for {from, to, type, what} <- edge_specs(e, me, created) do
      case write_edge(from, to, type, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Repo.rollback({:entry_failed, e, :invalid, "cannot #{what}: #{describe(reason)}"})
      end
    end
  end

  defp edge_specs(e, me, created) do
    parent =
      case e.parent do
        nil -> []
        p -> [{real(p, created), me, :parent_of, "attach #{me} to its parent #{label_of(p)}"}]
      end

    deps =
      for d <- e.depends_on,
          do: {real(d, created), me, :blocks, "add dependency #{label_of(d)} -> #{me}"}

    blocks =
      for b <- e.blocks,
          do: {me, real(b, created), :blocks, "add dependency #{me} -> #{label_of(b)}"}

    parent ++ deps ++ blocks
  end

  defp real({:id, id}, _created), do: id
  defp real({:ref, ref}, created), do: Map.fetch!(created.by_ref, ref)

  defp label_of({:id, id}), do: id
  defp label_of({:ref, ref}), do: "ref #{inspect(ref)}"

  defp write_edge(from, to, type, opts) do
    writer = Keyword.get(opts, :edge_writer, &Dependencies.add/4)
    edge_opts = opts |> Keyword.take([:created_by]) |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case writer.(from, to, type, edge_opts) do
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe({_kind, message}) when is_binary(message), do: message
  defp describe({:error, reason}), do: describe(reason)
  defp describe(other), do: inspect(other)

  # ---- finish ---------------------------------------------------------------

  # After the commit: mirror upstream, then (optionally) promote.
  defp finish(entries, created, opts) do
    tickets =
      for e <- entries do
        issue = Map.fetch!(created.by_index, e.index)

        {issue, upstream} =
          if truthy?(e.attrs["skip_upstream_create"]),
            do: {issue, nil},
            else: CreateUpstream.mirror(issue)

        # The in-transaction `:created` broadcast fired before the commit; tell the
        # board again now that the ticket is really there.
        Issue.broadcast_lifecycle(:updated, issue)

        %{
          index: e.index,
          ref: e.ref,
          issue: issue,
          warnings: Create.warnings(issue),
          failures: List.wrap(upstream)
        }
      end

    edges =
      for e <- entries,
          me = Map.fetch!(created.by_index, e.index).id,
          {from, to, type, _} <- edge_specs(e, me, created),
          do: %{from: from, to: to, type: type}

    {:ok,
     %{
       tickets: tickets,
       refs: created.by_ref,
       edges: edges,
       promote: if(Keyword.get(opts, :promote, false) == true, do: promote(tickets, opts))
     }}
  end

  defp promote(tickets, opts) do
    promoter = Keyword.get(opts, :promoter, &default_promoter(&1, opts))

    tickets
    |> Enum.map(& &1.issue.id)
    |> BulkResult.run(fn id ->
      case Ash.get(Issue, id) do
        {:ok, issue} -> promoter.(issue)
        {:error, _} = err -> err
      end
    end)
  end

  defp default_promoter(issue, opts) do
    args = Keyword.get(opts, :promote_args, %{})

    case Ash.update(issue, args, action: :promote_to_ready) do
      {:ok, promoted} -> {:ok, %{id: promoted.id, state: to_string(promoted.state)}}
      {:error, _} = err -> err
    end
  end

  @doc """
  The wire shape of a successful `run/2`, shared by REST and MCP:

      %{refs: %{ref => id}, counts: %{tickets: n, edges: n},
        tickets: [%{index:, ref:, id:, title:, state:, warnings: […], failures: […]}],
        edges: [%{from_issue_id:, to_issue_id:, type:}],
        promote: %{results: […], counts: %{…}}}   # only when `promote: true`

  `warnings` / `failures` appear only on a ticket that has some (a missing
  acceptance warning; a failed tracker mirror — the ticket exists either way).
  """
  @spec present(map()) :: map()
  def present(%{tickets: tickets, refs: refs, edges: edges, promote: promote}) do
    base = %{
      refs: refs,
      counts: %{tickets: length(tickets), edges: length(edges)},
      tickets: Enum.map(tickets, &present_ticket/1),
      edges:
        Enum.map(edges, &%{from_issue_id: &1.from, to_issue_id: &1.to, type: to_string(&1.type)})
    }

    if promote, do: Map.put(base, :promote, promote), else: base
  end

  defp present_ticket(t) do
    %{
      index: t.index,
      ref: t.ref,
      id: t.issue.id,
      title: t.issue.title,
      state: to_string(t.issue.state)
    }
    |> put_unless_empty(:warnings, t.warnings)
    |> put_unless_empty(:failures, Enum.map(t.failures, &Map.take(&1, [:kind, :message])))
  end

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp truthy?(v), do: v in [true, "true", "1", 1]

  # ---- errors ---------------------------------------------------------------

  defp reason_parts({kind, message}) when is_atom(kind) and is_binary(message),
    do: {kind, message}

  defp reason_parts(%{__exception__: true} = e), do: {:invalid, Exception.message(e)}
  defp reason_parts(other), do: {:invalid, inspect(other)}

  defp error(kind, e, message, extra \\ %{}) do
    title = Map.get(e, :title) || get_in_attrs(e)
    ref = Map.get(e, :ref)

    label =
      "tickets[#{e.index}]" <>
        if(ref, do: " (ref #{inspect(ref)})", else: "") <>
        if(is_binary(title), do: " #{inspect(title)}", else: "")

    {:error,
     {kind, "#{label}: #{message}", Map.merge(%{index: e.index, ref: ref, title: title}, extra)}}
  end

  defp get_in_attrs(%{attrs: %{"title" => t}}), do: t
  defp get_in_attrs(_), do: nil
end
