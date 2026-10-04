defmodule Arbiter.Extensions.Core.Values do
  @moduledoc """
  The module core's `:issue_type` and `:session_kind` keys point at; see
  `Arbiter.Extension.Value`.
  """

  @behaviour Arbiter.Extension.Value

  @impl true
  def description, do: "core value"
end
