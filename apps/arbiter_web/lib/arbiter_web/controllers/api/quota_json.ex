defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  # The body is `Arbiter.Quota.snapshot_view/1`, shared with MCP `quota_get`.
  def show(assigns), do: %{data: Arbiter.Quota.snapshot_view(assigns)}
end
