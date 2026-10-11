defmodule Arbiter.Tasks.WorkerFiling do
  @moduledoc """
  What a **worker**-tier caller may file: a follow-up ticket as a child of its
  own task, and the `parent_of` edge that adopts a ticket under it
  (bd-dtfe9x, D-T-21). One rule set behind both surfaces — the REST routes
  (`ArbiterWeb.ApiPolicy` `:issue_create` / `:dependency_add`) and the
  `ticket_create` / `dep_add` MCP tools — so a worker cannot do on one what the
  other refuses.

  Both functions take the string-keyed params/args map the surface already
  holds and return `:ok | {:error, message}`; the surface wraps the message in
  its own error shape. Neither raises for an unknown id — an id that does not
  exist falls through to the surface's own 404.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Dependencies, Issue}

  # What a worker may set on a follow-up it files (`arb create`'s descriptive
  # flags). No `repo` / `target_branch` / `tracker_ref` / `auto_close` /
  # `verify_after_deploy`: where and how work ships stays coordinator authority.
  @create_params ~w(title description acceptance workspace_id parent_id issue_type
                    priority difficulty skip_upstream_create force)

  # `parent_of` from the worker's own task is the only edge it may add, and only
  # these params ride along — `notes`/`created_by` stay coordinator authority
  # (`created_by` would let a worker forge who made the edge).
  @dependency_params ~w(from_issue_id to_issue_id type)

  @doc "The params a worker may send when filing a ticket."
  @spec create_params() :: [String.t()]
  def create_params, do: @create_params

  @doc """
  A worker files only a child of its own task, in its own workspace, with only
  the descriptive fields in `create_params/0`. A new ticket starts in Backlog,
  so nothing a worker files dispatches.
  """
  @spec authorize_create(Scope.t(), map()) :: :ok | {:error, String.t()}
  def authorize_create(%Scope{tier: :worker} = scope, params) when is_map(params) do
    extra = params |> Map.keys() |> Enum.reject(&(&1 in @create_params))

    cond do
      params["parent_id"] != scope.task_id ->
        {:error, "may only file a ticket as a child of its own task (parent_id)"}

      params["workspace_id"] != scope.workspace_id ->
        {:error, "may only file a ticket in its own workspace"}

      extra != [] ->
        {:error, "may not set #{Enum.join(extra, ", ")} on a ticket it files"}

      true ->
        :ok
    end
  end

  @doc """
  A worker's batch (`tickets: [...]`) is held to the single-create rule **per
  entry**: every entry must be a child of the worker's own task (`parent_id` is
  the worker's task id — an in-batch `ref` does not qualify), in its own
  workspace, with only the descriptive fields (`ref` is the one batch-only key it
  may add). `depends_on` / `blocks` and `promote` are coordinator authority. The
  refusal names the entry (`tickets[i]`).
  """
  @spec authorize_batch(Scope.t(), map()) :: :ok | {:error, String.t()}
  def authorize_batch(%Scope{tier: :worker} = scope, params) when is_map(params) do
    tickets = params["tickets"]

    cond do
      params["promote"] in [true, "true"] ->
        {:error, "may not promote the tickets it files (a new ticket starts in Backlog)"}

      is_list(tickets) ->
        tickets
        |> Enum.with_index()
        |> Enum.find_value(:ok, fn {entry, i} ->
          authorize_batch_entry(scope, params, entry, i)
        end)

      true ->
        :ok
    end
  end

  defp authorize_batch_entry(scope, params, %{} = entry, i) do
    entry =
      entry
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.delete("ref")
      |> Map.put_new("workspace_id", params["workspace_id"])

    case authorize_create(scope, entry) do
      :ok -> nil
      {:error, why} -> {:error, "tickets[#{i}]: #{why}"}
    end
  end

  defp authorize_batch_entry(_scope, _params, _entry, _i), do: nil

  @doc """
  The single-edge rule for one edge of a bulk `dep_add`, given as the normalized
  `%{from:, to:, type:, notes:?}` of `Arbiter.Tasks.BulkEdges`. A worker's edge
  the rule refuses becomes that edge's `rejected` outcome; the rest still apply.
  """
  @spec authorize_edge(Scope.t(), map()) :: :ok | {:error, String.t()}
  def authorize_edge(%Scope{tier: :worker} = scope, %{from: from, to: to, type: type} = edge) do
    params =
      %{"from_issue_id" => from, "to_issue_id" => to, "type" => to_string(type)}
      |> then(&if(Map.has_key?(edge, :notes), do: Map.put(&1, "notes", edge.notes), else: &1))

    authorize_dependency(scope, params)
  end

  def authorize_edge(%Scope{}, _edge), do: :ok

  @doc """
  A worker adds the `parent_of` edge from its own task to a ticket in its
  workspace that has no parent yet — the second half of `arb create --parent`.
  """
  @spec authorize_dependency(Scope.t(), map()) :: :ok | {:error, String.t()}
  def authorize_dependency(%Scope{tier: :worker} = scope, params) when is_map(params) do
    extra = params |> Map.keys() |> Enum.reject(&(&1 in @dependency_params))

    cond do
      params["from_issue_id"] != scope.task_id or params["type"] != "parent_of" ->
        {:error, "may only add a parent_of edge from its own task"}

      extra != [] ->
        {:error, "may not set #{Enum.join(extra, ", ")} on an edge it adds"}

      not issue_in_workspace?(params["to_issue_id"], scope.workspace_id) ->
        {:error, "may only adopt a ticket in its own workspace"}

      has_parent?(params["to_issue_id"]) ->
        {:error, "may only adopt a ticket that has no parent yet"}

      true ->
        :ok
    end
  end

  @doc """
  Whether `issue_id` lives in `workspace_id`. An issue the caller cannot see is
  "not yours" — but an id that does not exist at all answers `true`, so the
  surface's own 404 fires instead of a misleading 403.
  """
  @spec issue_in_workspace?(term(), String.t() | nil) :: boolean()
  def issue_in_workspace?(issue_id, workspace_id) when is_binary(issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, %{workspace_id: ws}} -> ws == workspace_id
      {:error, _} -> true
    end
  end

  def issue_in_workspace?(_issue_id, _workspace_id), do: false

  defp has_parent?(issue_id) do
    case Dependencies.list(issue_id: issue_id) do
      {:ok, deps} ->
        Enum.any?(deps, &(&1.edge.type == :parent_of and &1.edge.to_issue_id == issue_id))

      _ ->
        true
    end
  end
end
