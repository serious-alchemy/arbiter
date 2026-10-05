defmodule Arbiter.Tasks.Workspace.ConfigPolicy.Default do
  @moduledoc "Default `Arbiter.Tasks.Workspace.ConfigPolicy`: allows every config."

  @behaviour Arbiter.Tasks.Workspace.ConfigPolicy

  @impl true
  def check(_config, _context), do: :ok
end
