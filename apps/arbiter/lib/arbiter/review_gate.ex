defmodule Arbiter.ReviewGate do
  @moduledoc """
  Ash domain for durable, structured `Arbiter.Worker.ReviewGate` round outcomes
  (bd-aqyjuc), and the coordinator's recorded answer when a gate escalates
  (bd-4qjl0q).

  See `Arbiter.ReviewGate.Round` and `Arbiter.ReviewGate.Resolution` for the
  schemas and rationale.
  """

  use Ash.Domain

  resources do
    resource Arbiter.ReviewGate.Round
    resource Arbiter.ReviewGate.Resolution
  end
end
