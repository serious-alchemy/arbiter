defmodule Arbiter.Test.RaisingReplayRunner do
  @moduledoc """
  An `Arbiter.Loop.Replay.Runner` whose `layout/2` raises (bd-c7lx65), for the
  test that such a replay is refused before admission and leaves no record.
  """

  @behaviour Arbiter.Loop.Replay.Runner

  @impl true
  def layout(_role, _spec), do: raise("layout exploded")

  @impl true
  def run(_role, _spec), do: {:error, :never_reached}
end
