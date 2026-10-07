defmodule Arbiter.Parity.Manifest do
  @moduledoc """
  The MCP / CLI / REST parity manifest, `priv/parity/manifest.exs`.

  One row per operation, mapping it to the MCP tool(s), `arb` verb(s) and REST
  route(s) that reach it, with a status and a ruling for every surface that
  lacks it. The file documents its own row format.

  Three guard tests read it, one per app so each sees its own enumeration:
  `arbiter` (the MCP catalog), `arbiter_web` (the router and `ApiPolicy`) and
  `arbiter_cli` (`ArbiterCli.Verbs`). A fourth, in `arbiter`, runs `problems/1`
  over the manifest itself. This module is the shared reader plus the failure
  messages, which say how to add the missing row.
  """

  @path "priv/parity/manifest.exs"
  @surfaces [:mcp, :cli, :rest]
  @statuses [:full, :partial, :excluded]
  @rest_cell ~r/^(GET|POST|PUT|PATCH|DELETE|WS) \//

  @type surface :: :mcp | :cli | :rest
  @type ruling :: {:intentional, String.t()} | {:gap, String.t(), String.t()}
  @type operation :: %{
          required(:id) => String.t(),
          required(:title) => String.t(),
          required(:mcp) => [String.t()] | nil,
          required(:cli) => [String.t()] | nil,
          required(:rest) => [String.t()] | nil,
          required(:status) => :full | :partial | :excluded | {:gap, String.t()},
          optional(:absent) => %{optional(surface()) => ruling()},
          optional(:divergences) => [String.t()],
          optional(:note) => String.t()
        }
  @type t :: %{children: %{String.t() => String.t()}, operations: [operation()]}

  @doc "Where the manifest lives, inside the `:arbiter` app's priv dir."
  @spec path() :: Path.t()
  def path, do: Application.app_dir(:arbiter, @path)

  @doc """
  Read the manifest term. The file is a plain literal (maps, lists, tuples,
  strings, atoms); it is parsed and converted without being evaluated, so
  anything that is not a literal raises.
  """
  @spec load!() :: t()
  def load! do
    path() |> File.read!() |> Code.string_to_quoted!(file: path()) |> literal!()
  end

  @doc "Every MCP tool name the manifest mentions (canonical names and aliases)."
  @spec mcp_tools(t()) :: [String.t()]
  def mcp_tools(manifest \\ load!()), do: cells(manifest, :mcp)

  @doc "Every `\"METHOD /path\"` REST cell the manifest mentions."
  @spec rest_routes(t()) :: [String.t()]
  def rest_routes(manifest \\ load!()), do: cells(manifest, :rest)

  @doc "Every `arb ...` command spelling the manifest mentions."
  @spec cli_commands(t()) :: [String.t()]
  def cli_commands(manifest \\ load!()), do: cells(manifest, :cli)

  @doc "The first token after `arb` of every CLI cell, i.e. the `Verbs` entry name."
  @spec cli_verbs(t()) :: [String.t()]
  def cli_verbs(manifest \\ load!()) do
    manifest
    |> cli_commands()
    |> Enum.map(fn "arb " <> rest -> rest |> String.split(" ", parts: 2) |> hd() end)
    |> Enum.uniq()
  end

  @doc """
  The manifest's `[verb]` / `[route]` cells that the live enumeration does not
  know about, for the reverse ("no stale row") check.
  """
  @spec stale_message(surface(), [String.t()]) :: String.t()
  def stale_message(kind, stale) do
    """
    The parity manifest names #{label(kind)} that no longer exist: #{Enum.join(stale, ", ")}

    Fix apps/arbiter/#{@path}: remove or rename the value in the row's `#{kind}:` cell. If the
    surface was dropped deliberately, set the cell to nil and add an `absent: %{#{kind}: ...}`
    ruling saying why.
    """
  end

  @doc """
  The failure message for a surface item with no manifest row. Names the row,
  and says how to add it.
  """
  @spec missing_message(surface(), [String.t()]) :: String.t()
  def missing_message(kind, missing) do
    """
    #{label(kind)} with no row in the parity manifest:

    #{Enum.map_join(missing, "\n", &("  * " <> &1))}

    Add each to apps/arbiter/#{@path}, under `operations:`. If the operation is already a
    row (the same thing on another surface), put the name in that row's `#{kind}:` cell;
    otherwise add a row:

        %{
          id: "<domain>/<slug>",
          title: "one line",
          mcp: ["tool_name"] | nil,
          cli: ["arb verb sub"] | nil,
          rest: ["GET /api/path"] | nil,
          status: :full | :partial | :excluded | {:gap, "P-xx"},
          absent: %{cli: {:intentional, "why it is absent"}}   # one ruling per nil cell
        }

    A nil cell needs a ruling: `{:intentional, "reason"}` (the operation should not exist on
    that surface) or `{:gap, "P-xx", "what is missing"}` naming an open child in `children:`.
    The file header documents the fields. Example for this check: #{example(kind)}
    """
  end

  @doc """
  Defects in a manifest term, as one line each (`[]` when it is sound): shape,
  unique ids, a ruling for every nil cell and none for a present one, gap ids
  that name a listed child, listed children that some row still cites, and a
  status that agrees with the rulings.
  """
  @spec problems(term()) :: [String.t()]
  def problems(%{children: children, operations: ops}) when is_map(children) and is_list(ops) do
    ids = Enum.map(ops, &Map.get(&1, :id))

    dups =
      for {id, n} <- Enum.frequencies(ids), n > 1, do: "duplicate id #{id}"

    cited = for op <- ops, {_, {:gap, id, _}} <- Map.get(op, :absent, %{}), do: id

    unknown =
      for id <- Enum.uniq(cited), not Map.has_key?(children, id) do
        "#{id} is not in `children` (a gap must name an open child, or be :intentional)"
      end

    uncited =
      for id <- Map.keys(children), id not in cited do
        "#{id} is in `children` but no row cites it (the child landed? delete the entry)"
      end

    dups ++ Enum.flat_map(ops, &op_problems/1) ++ unknown ++ uncited
  end

  def problems(_), do: ["manifest must be %{children: map, operations: list}"]

  # ---- internals -----------------------------------------------------------

  defp literal!({:%{}, _, pairs}), do: Map.new(pairs, fn {k, v} -> {literal!(k), literal!(v)} end)
  defp literal!({:{}, _, elems}), do: elems |> Enum.map(&literal!/1) |> List.to_tuple()
  defp literal!({a, b}), do: {literal!(a), literal!(b)}
  defp literal!(list) when is_list(list), do: Enum.map(list, &literal!/1)
  defp literal!(lit) when is_binary(lit) or is_atom(lit) or is_number(lit), do: lit

  defp literal!(other),
    do: raise(ArgumentError, "#{@path} must be a plain literal, found #{Macro.to_string(other)}")

  defp cells(%{operations: ops}, surface) do
    ops |> Enum.flat_map(&(Map.get(&1, surface) || [])) |> Enum.uniq()
  end

  defp op_problems(%{id: id} = op) when is_binary(id) do
    absent = Map.get(op, :absent, %{})

    for(
      problem <- shape_problems(op) ++ ruling_problems(op, absent) ++ status_problems(op, absent),
      do: "#{id}: #{problem}"
    )
  end

  defp op_problems(op), do: ["row without a string id: #{inspect(op, limit: 5)}"]

  defp shape_problems(op) do
    title =
      if is_binary(op[:title]) and op[:title] != "", do: [], else: ["title must be a string"]

    cells =
      Enum.flat_map(@surfaces, fn surface ->
        case Map.fetch(op, surface) do
          {:ok, nil} -> []
          {:ok, [_ | _] = list} -> Enum.flat_map(list, &cell_problem(surface, &1))
          _ -> ["#{surface} must be nil or a non-empty list"]
        end
      end)

    title ++ cells
  end

  defp cell_problem(:mcp, v) when is_binary(v) and v != "", do: []
  defp cell_problem(:cli, "arb " <> _), do: []

  defp cell_problem(:rest, v) when is_binary(v),
    do:
      if(Regex.match?(@rest_cell, v),
        do: [],
        else: ["rest cell #{inspect(v)} is not \"METHOD /path\""]
      )

  defp cell_problem(surface, v), do: ["bad #{surface} cell #{inspect(v)}"]

  defp ruling_problems(op, absent) when is_map(absent) do
    unknown =
      for k <- Map.keys(absent), k not in @surfaces, do: "unknown surface #{inspect(k)} in absent"

    per_surface =
      Enum.flat_map(@surfaces, fn surface ->
        nil? = Map.get(op, surface) == nil

        case {nil?, Map.fetch(absent, surface)} do
          {true, :error} -> ["no ruling for nil #{surface}"]
          {false, {:ok, _}} -> ["#{surface} has a value and a ruling (drop the ruling)"]
          {_, {:ok, ruling}} -> one_ruling(surface, ruling)
          {false, :error} -> []
        end
      end)

    unknown ++ per_surface
  end

  defp ruling_problems(_op, _), do: ["absent must be a map"]

  defp one_ruling(surface, {:intentional, reason}), do: reason_problem(surface, reason)

  defp one_ruling(surface, {:gap, id, reason}) when is_binary(id) do
    if id =~ ~r/^P-\d+$/,
      do: reason_problem(surface, reason),
      else: ["#{surface} gap id #{inspect(id)} is not P-<number>"]
  end

  defp one_ruling(surface, other),
    do: [
      "#{surface} ruling must be {:intentional, why} or {:gap, \"P-xx\", what}: #{inspect(other)}"
    ]

  defp reason_problem(surface, reason) do
    if is_binary(reason) and String.trim(reason) != "",
      do: [],
      else: ["#{surface} ruling has an empty reason"]
  end

  defp status_problems(op, absent) when is_map(absent) do
    gap_ids = for {_, {:gap, id, _}} <- absent, uniq: true, do: id
    nil_count = Enum.count(@surfaces, &(Map.get(op, &1) == nil))

    case {op[:status], gap_ids} do
      {{:gap, id}, [_ | _]} ->
        if id in gap_ids,
          do: [],
          else: ["status must be {:gap, #{inspect(hd(gap_ids))}} (a gap id of this row)"]

      {{:gap, id}, []} ->
        ["status {:gap, #{inspect(id)}} but no nil cell has a :gap ruling"]

      {_, [first | _]} ->
        ["status must be {:gap, #{inspect(first)}}: a nil cell is an open gap"]

      {:excluded, []} when nil_count == 0 ->
        ["status :excluded needs at least one nil cell"]

      {status, []} when status in @statuses ->
        []

      {status, []} ->
        ["bad status #{inspect(status)}"]
    end
  end

  defp status_problems(_op, _), do: []

  defp label(:mcp), do: "MCP tools"
  defp label(:cli), do: "`arb` verbs"
  defp label(:rest), do: "REST routes"

  defp example(:mcp), do: ~s|mcp: ["brand_new_tool"]|
  defp example(:cli), do: ~s|cli: ["arb brand-new-verb"]|
  defp example(:rest), do: ~s|rest: ["GET /api/brand/new"]|
end
