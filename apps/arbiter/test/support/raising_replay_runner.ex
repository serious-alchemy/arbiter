defmodule Arbiter.Test.RaisingReplayRunner do
  @moduledoc """
  An `Arbiter.Loop.Replay.Runner` whose `layout/2` raises (bd-c7lx65), for the
  test that a replay's record is finished whatever its runner does.
  """

  @behaviour Arbiter.Loop.Replay.Runner

  @impl true
  def layout(_role, _spec), do: raise("layout exploded")

  @impl true
  def run(_role, _spec), do: {:error, :never_reached}
end
