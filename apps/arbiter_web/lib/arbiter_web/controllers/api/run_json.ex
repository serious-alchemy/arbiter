defmodule ArbiterWeb.Api.RunJSON do
  @moduledoc """
  Render functions for `Arbiter.Workers.Run`, through the one
  `Arbiter.Workers.Serializer` the MCP `worker_runs` tool renders with.

  `:index` omits `output_lines` (which can be up to 500 strings) to keep list
  responses compact — clients fetch full output through `:show`.
  """

  alias Arbiter.Workers.Serializer

  def index(%{runs: runs}) do
    %{data: Enum.map(runs, &Serializer.run_summary/1)}
  end

  def show(%{run: run}), do: %{data: Serializer.run_detail(run)}
end
