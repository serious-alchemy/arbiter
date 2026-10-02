defmodule Arbiter.MCP.Tools.MemoryPending do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for memory promotion (phase 13).
  Provides `memory_pending_list`, `memory_pending_diff`, `memory_pending_apply`,
  and `memory_pending_reject`.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions.Memory.Promotion

  def memory_pending_list(%Scope{}, _args) do
    candidates = Promotion.list_candidates()
    {:ok, %{candidates: candidates, count: length(candidates)}}
  end

  def memory_pending_diff(%Scope{}, %{"path" => path}) do
    case Promotion.diff(path) do
      {:ok, diff} -> {:ok, %{diff: diff}}
      {:error, :invalid_path} -> {:error, {:invalid_arguments, "Invalid candidate path"}}
      {:error, {:system_error, reason}} -> {:error, {:system_error, inspect(reason)}}
    end
  end

  def memory_pending_diff(_, _), do: {:error, {:invalid_arguments, "Missing path"}}

  def memory_pending_apply(%Scope{}, %{"path" => path} = args) do
    overwrite? = Map.get(args, "overwrite", false)

    case Promotion.promote(path, overwrite: overwrite?) do
      :ok ->
        {:ok, %{status: "promoted"}}

      {:error, :exists} ->
        {:error,
         {:system_error,
          "Memory already exists in shared layer. Pass overwrite: true to overwrite."}}

      {:error, :invalid_path} ->
        {:error, {:invalid_arguments, "Invalid candidate path"}}

      {:error, :stale} ->
        {:error, {:system_error, "Memory has stale citations and cannot be promoted"}}

      {:error, {:system_error, reason}} ->
        {:error, {:system_error, inspect(reason)}}
    end
  end

  def memory_pending_apply(_, _), do: {:error, {:invalid_arguments, "Missing path"}}

  def memory_pending_reject(%Scope{}, %{"path" => path}) do
    case Promotion.reject(path) do
      :ok -> {:ok, %{status: "rejected"}}
      {:error, :invalid_path} -> {:error, {:invalid_arguments, "Invalid candidate path"}}
      {:error, {:system_error, reason}} -> {:error, {:system_error, inspect(reason)}}
    end
  end

  def memory_pending_reject(_, _), do: {:error, {:invalid_arguments, "Missing path"}}
end
