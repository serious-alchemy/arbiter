defmodule Arbiter.StandingOrders do
  @moduledoc """
  Shared utilities for rendering standing orders consistently across the app.
  """

  alias Arbiter.Tasks.Workspace

  @heading "## Workspace standing orders"

  @doc """
  The workspace's effective standing-order text — one canonical line per order,
  newline-joined — or `nil` when unset/empty. This is the single source for both
  the text injected into worker prompts (`section/1`) and the provenance digest
  (`Arbiter.Worker.RunProvenance.standing_orders_digest/1`), so the digest always
  covers exactly what a worker was shown.
  """
  @spec text(Workspace.t() | nil) :: String.t() | nil
  def text(%Workspace{config: config}) do
    case get_in(config || %{}, ["standing_orders"]) do
      orders when is_list(orders) and orders != [] ->
        Enum.map_join(orders, "\n", &canonical_text/1)

      text when is_binary(text) and text != "" ->
        text

      _ ->
        nil
    end
  end

  def text(_), do: nil

  @doc """
  The labelled prompt section carrying the workspace's standing orders, or `""`
  when it has none (so a workspace without orders leaves prompts unchanged).
  """
  @spec section(Workspace.t() | nil) :: String.t()
  def section(ws) do
    case text(ws) do
      nil ->
        ""

      text ->
        """
        #{@heading}

        The operator set these standing orders for this workspace (one per line). Follow them in addition to the task below.

        #{text}

        """
    end
  end

  @doc """
  Render a standing order element to canonical text (no display prefix).
  Handles both string and `{"title", "detail"}` map formats, normalizing them
  for consistent hashing. Used by `Arbiter.Worker.RunProvenance` for
  dispatch-time provenance hashing; `ArbiterCli.Cmd.Prime.standing_order_line/1`
  and `standing_orders_component.ex` still hold separate rendering copies
  pending a follow-up ticket to unify them.
  """
  @spec canonical_text(any()) :: String.t()
  def canonical_text(%{"title" => title} = order) when is_binary(title) do
    case order["detail"] do
      detail when is_binary(detail) and detail != "" -> "#{title} — #{detail}"
      _ -> title
    end
  end

  def canonical_text(text) when is_binary(text), do: text
  def canonical_text(other), do: inspect(other)
end
