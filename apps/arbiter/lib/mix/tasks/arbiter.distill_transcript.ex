defmodule Mix.Tasks.Arbiter.DistillTranscript do
  use Mix.Task

  @shortdoc "Runs transcript distillation on a session"

  @moduledoc """
  Operator-invoked entry point for the phase-14 transcript distillation pass.

  Usage:
      mix arbiter.distill_transcript <session_id>
  """

  def run([session_id]) do
    {:ok, _} = Application.ensure_all_started(:arbiter)

    case Arbiter.Sessions.TranscriptDistillation.run(session_id) do
      {:ok, candidates} ->
        Mix.shell().info("Distilled #{length(candidates)} candidates.")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix arbiter.distill_transcript <session_id>")
  end
end
