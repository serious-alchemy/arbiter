defmodule Arbiter.Tasks.BulkResult do
  @moduledoc """
  The shared per-id result contract for bulk ticket verbs (promote / demote /
  rank, and the sibling bulk update / close / verify verbs).

  A bulk call is never all-or-nothing: each id is applied on its own and gets
  an outcome

      %{id: "bd-1", status: "ok" | "refused" | "not_found", reason: "…", ticket: %{…}}

  `reason` is present unless `ok`; `ticket` is the single-id response body for
  that id (present when `ok`). The overall response is

      %{results: [outcome, …], counts: %{total: n, ok: n, refused: n, not_found: n}}

  in the order the ids were given. Batches are capped at `max_batch/0` ids.

  Callers pass `run/2` a function from an id to `{:ok, ticket}` or
  `{:error, reason}`, where `reason` is a `{kind, message}` tuple (`:not_found`
  is the only kind classified `not_found`), an Ash error (a
  `Ash.Error.Query.NotFound` anywhere inside is `not_found`), or a string.
  """

  @max_batch 200
  @statuses ~w(ok refused not_found)

  @type outcome :: %{
          required(:id) => String.t(),
          required(:status) => String.t(),
          optional(:reason) => String.t(),
          optional(:ticket) => term()
        }

  @doc "Largest number of ids one bulk call accepts."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc "The three per-id statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Read the `ids` list from request params / tool args. Trims, drops blanks and
  de-duplicates (first occurrence wins). `{:error, message}` for a missing,
  empty, malformed or over-cap list.
  """
  @spec fetch_ids(map()) :: {:ok, [String.t()]} | {:error, String.t()}
  def fetch_ids(params) do
    case Map.get(params, "ids") do
      ids when is_list(ids) ->
        if Enum.all?(ids, &is_binary/1),
          do: check_ids(ids),
          else: {:error, "`ids` must be an array of ticket id strings"}

      _ ->
        {:error, "`ids` must be a non-empty array of ticket id strings"}
    end
  end

  defp check_ids(ids) do
    ids = ids |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, "`ids` must be a non-empty array of ticket id strings"}

      length(ids) > @max_batch ->
        {:error, "too many ids: a bulk call takes at most #{@max_batch}, got #{length(ids)}"}

      true ->
        {:ok, ids}
    end
  end

  @doc "Apply `fun` to each id in order and build the overall response."
  @spec run([String.t()], (String.t() -> {:ok, term()} | {:error, term()})) :: %{
          results: [outcome()],
          counts: map()
        }
  def run(ids, fun) when is_function(fun, 1) do
    summarize(Enum.map(ids, fn id -> outcome(id, fun.(id)) end))
  end

  @doc """
  Like `run/2` for a bulk rank. `ids` is an **ordered list** and `args` the one
  shared move (string keys `top` / `bottom` / `before_id` / `after_id` /
  `pinned`, exactly as a single-id rank takes them); the ids end up in list
  order:

    * `top` — the ids form a block at the top, `ids[0]` first;
    * `bottom` — the ids form a block at the bottom, `ids[0]` first of them;
    * `after_id: X` — `ids[0]` goes right after `X`, each next id after the one before it;
    * `before_id: X` — the ids sit, in order, immediately ahead of `X`;
    * `pinned` alone — each id is pinned/unpinned, order is irrelevant.

  `fun` receives the id and its single-id args. Results come back in `ids` order.
  """
  @spec run_rank([String.t()], map(), (String.t(), map() -> {:ok, term()} | {:error, term()})) ::
          %{results: [outcome()], counts: map()}
  def run_rank(ids, args, fun) when is_function(fun, 2) do
    top? = Map.get(args, "top") in [true, "true"]
    ordered = if top?, do: Enum.reverse(ids), else: ids

    steps =
      if is_binary(args["after_id"]) do
        anchors = [args["after_id"] | ids]

        ordered
        |> Enum.zip(anchors)
        |> Enum.map(fn {id, anchor} -> {id, Map.put(args, "after_id", anchor)} end)
      else
        Enum.map(ordered, &{&1, args})
      end

    results = Enum.map(steps, fn {id, step_args} -> outcome(id, fun.(id, step_args)) end)
    summarize(if top?, do: Enum.reverse(results), else: results)
  end

  @doc "Build the overall response from already-built outcomes."
  @spec summarize([outcome()]) :: %{results: [outcome()], counts: map()}
  def summarize(results) do
    base = Map.new(@statuses, &{String.to_existing_atom(&1), 0})

    counts =
      Enum.reduce(results, base, fn %{status: s}, acc ->
        Map.update!(acc, String.to_existing_atom(s), &(&1 + 1))
      end)

    %{results: results, counts: Map.put(counts, :total, length(results))}
  end

  @doc "Build one outcome from a single-id result."
  @spec outcome(String.t(), {:ok, term()} | {:error, term()}) :: outcome()
  def outcome(id, {:ok, ticket}), do: %{id: id, status: "ok", ticket: ticket}

  def outcome(id, {:error, reason}) do
    %{id: id, status: status_for(reason), reason: reason_text(reason)}
  end

  defp status_for({:not_found, _}), do: "not_found"
  defp status_for(:not_found), do: "not_found"

  defp status_for(%{__struct__: _} = err),
    do: if(not_found?(err), do: "not_found", else: "refused")

  defp status_for(_), do: "refused"

  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &not_found?/1)
  defp not_found?(_), do: false

  defp reason_text({_kind, msg}) when is_binary(msg), do: msg
  defp reason_text(msg) when is_binary(msg), do: msg
  defp reason_text(:not_found), do: "not found"

  defp reason_text(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  end

  defp reason_text(other), do: inspect(other)
end
