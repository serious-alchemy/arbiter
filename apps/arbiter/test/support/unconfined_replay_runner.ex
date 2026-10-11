defmodule Arbiter.Test.UnconfinedReplayRunner do
  @moduledoc """
  An `Arbiter.Loop.Replay.Runner` that cannot confine the scoring reviewer
  (bd-c7lx65): `layout/2` refuses the `:review` side, as
  `Arbiter.Loop.Replay.CliRunner` refuses a model it would run unjailed on the
  host. It sends the calling (test) process each spec it is asked about.
  """

  @behaviour Arbiter.Loop.Replay.Runner

  @impl true
  def layout(role, spec) do
    send(self(), {:layout, role, spec})

    if role == :review,
      do: {:error, {:unconfined, :review, spec.provider}},
      else: {:ok, :sandbox}
  end

  @impl true
  def run(_role, _spec), do: {:error, :never_reached}
end
