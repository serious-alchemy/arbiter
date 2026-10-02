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
    diff = Promotion.diff(path)
    {:ok, %{diff: diff}}
  end
  def memory_pending_diff(_, _), do: {:error, {:invalid_arguments, "Missing path"}}

  def memory_pending_apply(%Scope{}, %{"path" => path}) do
    case Promotion.promote(path) do
      :ok -> {:ok, %{status: "promoted"}}
      {:error, reason} -> {:error, {:system_error, inspect(reason)}}
    end
  end
  def memory_pending_apply(_, _), do: {:error, {:invalid_arguments, "Missing path"}}

  def memory_pending_reject(%Scope{}, %{"path" => path}) do
    case Promotion.reject(path) do
      :ok -> {:ok, %{status: "rejected"}}
      {:error, reason} -> {:error, {:system_error, inspect(reason)}}
    end
  end
  def memory_pending_reject(_, _), do: {:error, {:invalid_arguments, "Missing path"}}
end
