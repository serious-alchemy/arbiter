defmodule Arbiter.Tasks.Create do
  @moduledoc """
  The one ticket-create path (P-14). REST `POST /api/issues`, MCP
  `ticket_create` and the dashboard's `TaskNewLive` all call `run/2`; none of
  them re-implements dedup, the upstream-failure drain, edge creation or the
  acceptance warning any more.

  `run/2` owns, in order:

    1. **Dedup** (`Arbiter.Tasks.Dedup`) unless `force: true`.
    2. **Edge preflight** — the `parent_id` parent and every `deps` ticket must
       exist and share the new ticket's workspace. A bad edge refuses the whole
       create *before* anything is written, which is what makes the create and
       its edges effectively atomic: only a race (an endpoint deleted between
       the preflight and the write) can fail an edge afterwards.
    3. `Ash.create(Issue, attrs)`.
    4. **The upstream-create failure drain** — `CreateUpstream` stashes its
       failure in the calling process's dictionary; draining it here, in the
       process that ran the create, is the only correct place.
    5. The `parent_of` edge (`parent_id` → new ticket) and one `blocks` edge per
       `deps` entry (dep → new ticket).
    6. The acceptance warning for a gated type filed without `acceptance`.

  ## Result

    * `{:ok, issue, warnings}` — created, edges attached.
    * `{:duplicate, {:local_dup, [Issue.t()]} | {:tracker_dup, [map()]}}` —
      refused by dedup; nothing was created.
    * `{:partial, issue, failures}` — the ticket **exists**, but the upstream
      mirror and/or an edge failed. `failures` is a non-empty list of maps with
      a `:kind` (`:upstream_create_failed` | `:edge_failed`), a `:message`
      that names the ticket id, and the kind's own detail keys. An issue cannot
      be un-created (its paper-trail version row pins it), so the contract is
      "the task exists, report what is missing" — callers must surface the id.
    * `{:error, {kind, message}}` — a preflight refusal (`:not_found`,
      `:invalid`); nothing was created.
    * `{:error, %Ash.Error.Invalid{}}` — the action rejected the attrs.

  ## Options

    * `:force` — skip dedup (default `false`).
    * `:deps` — ticket ids that block the new ticket (`blocks` edges).
    * `:created_by` — the attribution label stamped on the edges.
    * `:edge_writer` — `(from, to, type, opts -> result)`, default
      `Arbiter.Tasks.Dependencies.add/4`. A seam for the race tests.

  `attrs` may be string- or atom-keyed. `parent_id` is read from `attrs` (it is
  also an `Issue :create` argument, informing the tracker default).
  """

  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream

  @type failure :: %{
          required(:kind) => atom(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @type result ::
          {:ok, Issue.t(), [String.t()]}
          | {:duplicate, Dedup.result()}
          | {:partial, Issue.t(), [failure()]}
          | {:error, {atom(), String.t()}}
          | {:error, Exception.t()}

  @spec run(map(), keyword()) :: result()
  def run(attrs, opts \\ []) when is_map(attrs) do
    force? = Keyword.get(opts, :force, false) == true
    parent_id = blank_to_nil(fetch(attrs, :parent_id))
    deps = opts |> Keyword.get(:deps, []) |> List.wrap()

    with :ok <- dedup(attrs, force?),
         :ok <- preflight(fetch(attrs, :workspace_id), parent_id, deps) do
      create(attrs, parent_id, deps, opts)
    else
      {:dup, dup} -> {:duplicate, dup}
      {:error, _} = err -> err
    end
  end

  @doc "One operator-facing line for a `{:partial, _, failures}` result."
  @spec failure_message([failure()]) :: String.t()
  def failure_message(failures), do: Enum.map_join(failures, "; ", & &1.message)

  # ---- dedup ----------------------------------------------------------------

  defp dedup(attrs, force?) do
    result =
      Dedup.check(fetch(attrs, :title), fetch(attrs, :workspace_id),
        force: force?,
        skip_upstream_create: truthy?(fetch(attrs, :skip_upstream_create)) or local_child?(attrs),
        tracker_ref: fetch(attrs, :tracker_ref)
      )

    case result do
      :ok -> :ok
      dup -> {:dup, dup}
    end
  end

  # A child of a tracked parent is, by default, context-only (`tracker.child_policy`,
  # #1973) and a refine session's children always are: no upstream ticket will be
  # minted, so searching the tracker for a title clash would be a pointless
  # network call. An explicit `tracker_type` says "mint anyway" and keeps it. The
  # tracker leg is advisory, so a workspace that chose `child_policy: mint` merely
  # loses that one check for its children.
  defp local_child?(attrs) do
    fetch(attrs, :tracker_child_policy) in [:context_only, "context_only"] or
      (not is_nil(blank_to_nil(fetch(attrs, :parent_id))) and
         is_nil(blank_to_nil(fetch(attrs, :tracker_type))))
  end

  # ---- preflight ------------------------------------------------------------

  defp preflight(workspace_id, parent_id, deps) do
    [parent_id | deps]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case check_endpoint(id, workspace_id) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_endpoint(id, workspace_id) when is_binary(id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ws}} when is_nil(workspace_id) or ws == workspace_id ->
        :ok

      {:ok, %Issue{}} ->
        {:error,
         {:invalid,
          "#{id} is in a different workspace than the new ticket — relationships are within a single workspace"}}

      _ ->
        {:error, {:not_found, "ticket #{id} not found"}}
    end
  end

  defp check_endpoint(other, _workspace_id),
    do: {:error, {:invalid, "ticket id must be a string, got #{inspect(other)}"}}

  # ---- create ---------------------------------------------------------------

  defp create(attrs, parent_id, deps, opts) do
    case Ash.create(Issue, attrs) do
      {:ok, issue} ->
        upstream = CreateUpstream.last_error()
        edge_failures = attach_edges(issue, parent_id, deps, opts)

        case upstream_failures(upstream) ++ edge_failures do
          [] -> {:ok, issue, ac_warnings(issue)}
          failures -> {:partial, issue, failures}
        end

      {:error, _} = err ->
        err
    end
  end

  defp upstream_failures(nil), do: []

  defp upstream_failures(err) do
    [
      Map.merge(err, %{
        kind: err.kind,
        message: err.message
      })
    ]
  end

  # ---- edges ----------------------------------------------------------------

  defp attach_edges(issue, parent_id, deps, opts) do
    writer = Keyword.get(opts, :edge_writer, &Dependencies.add/4)
    edge_opts = opts |> Keyword.take([:created_by]) |> Enum.reject(fn {_, v} -> is_nil(v) end)

    parent_edge =
      if parent_id,
        do: [{parent_id, issue.id, :parent_of, "attach #{issue.id} to parent #{parent_id}"}],
        else: []

    dep_edges =
      for dep <- deps, do: {dep, issue.id, :blocks, "add dependency #{dep} -> #{issue.id}"}

    for {from, to, type, what} <- parent_edge ++ dep_edges,
        {:error, reason} <- [writer.(from, to, type, edge_opts)] do
      %{
        kind: :edge_failed,
        task_id: issue.id,
        edge: %{from: from, to: to, type: type},
        message:
          "ticket #{issue.id} was created, but failed to #{what}: #{describe(reason)} — " <>
            "the ticket is filed without that edge; add it with dep_add rather than filing again"
      }
    end
  end

  defp describe({_kind, message}) when is_binary(message), do: message
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other)

  # ---- warnings -------------------------------------------------------------

  # bd-7mbrlg: non-blocking heads-up at filing time — the task is created
  # either way, but promotion will later refuse it without `acceptance` or an
  # explicit `acceptance_waived` reason.
  defp ac_warnings(%Issue{} = issue) do
    if Issue.gated_type?(issue.issue_type) and blank?(issue.acceptance) do
      [
        "No acceptance criteria set. #{issue.issue_type} tasks need `acceptance` (or an " <>
          "explicit `acceptance_waived` reason) before they can be promoted to Ready."
      ]
    else
      []
    end
  end

  # ---- helpers --------------------------------------------------------------

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp truthy?(v), do: v in [true, "true", "1", 1]

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp blank?(nil), do: true
  defp blank?(str), do: String.trim(str) == ""
end
