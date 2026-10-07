defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  # The payload is built by `Arbiter.Quota.Snapshot`, shared with MCP `quota_get`.
  def show(%{data: data}), do: %{data: data}
end
