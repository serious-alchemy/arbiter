defmodule Arbiter.Sessions.TranscriptDistillation do
  @moduledoc """
  Phase 14 (bd-avt4lt): Transcript distillation pass.
  A bounded pass over a session's archived transcript that emits memory candidates
  into the phase-13 promotion queue.
  """

  require Logger

  alias Arbiter.Loop.Discovery.ClaudeInvoker
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.TranscriptReplay
  alias Arbiter.Usage.Event

  @default_max_bytes 100_000

  @doc """
  Runs the distillation pass for `session_id`.

  Options:
    * `:max_bytes` — scope bound: how many trailing bytes of transcript to read (default 100kB).
    * `:invoker` — model invoker function `(prompt, opts) -> {:ok, text, usage}`.
    * `:workspace_id` — for model attribution/quota.
  """
  def run(session_id, opts \\ []) when is_binary(session_id) do
    opts = Keyword.put_new(opts, :max_bytes, @default_max_bytes)

    case TranscriptReplay.read_tail(session_id, opts) do
      {:ok, %{data: data}} when byte_size(data) > 0 ->
        run_model(session_id, data, opts)

      {:ok, _} ->
        {:ok, []}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_model(session_id, transcript, opts) do
    started = System.monotonic_time(:millisecond)
    prompt = build_prompt(session_id, transcript)

    reply = invoke(prompt, opts)
    elapsed = System.monotonic_time(:millisecond) - started

    case reply do
      {:ok, text, usage} ->
        record_cost(usage, elapsed, session_id, opts)
        candidates = parse_candidates(text)
        write_candidates(session_id, candidates)
        {:ok, candidates}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke(prompt, opts) do
    invoker = Keyword.get(opts, :invoker, &ClaudeInvoker.invoke/2)
    invoker.(prompt, opts)
  end

  defp build_prompt(session_id, transcript) do
    """
    You are extracting memory candidates from a session transcript.
    The session ID is: #{session_id}

    Read the following transcript and identify facts, conventions, or context
    that should be saved to shared memory (types: user, feedback, reference, project).
    For each candidate, output a markdown block enclosed in ```markdown ... ```.
    Each block MUST include YAML frontmatter with `type`, `name`, `description`, `source_transcript`, and `turn_range`.
    Do not use `source_session`, use `source_transcript`.

    Example:
    ```markdown
    ---
    name: preferred_test_framework
    description: User prefers ExUnit
    metadata:
      type: user
    source_transcript: #{session_id}
    turn_range: 12-14
    ---
    The user prefers ExUnit for all Elixir tests.
    ```

    Transcript:
    <transcript>
    #{transcript}
    </transcript>
    """
  end

  defp parse_candidates(text) do
    Regex.scan(~r/```markdown\n(.*?)\n```/s, text)
    |> Enum.map(fn [_, content] -> content end)
  end

  defp write_candidates(session_id, candidates) do
    dir = Layout.memory_candidates_dir(session_id)
    File.mkdir_p!(dir)

    Enum.each(candidates, fn content ->
      name =
        case Regex.run(~r/^name:\s*([^\n]+)/m, content) do
          [_, n] -> String.trim(n)
          _ -> "candidate_#{System.unique_integer([:positive])}"
        end
        |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

      filename = "#{name}.md"

      # Ensure file exists without overriding if there's conflict
      path = free_name(dir, filename)

      # The frontmatter content must be preserved
      File.write!(path, content)
    end)
  end

  defp free_name(dir, filename) do
    stem = Path.rootname(filename)

    [filename]
    |> Stream.concat(
      Stream.repeatedly(fn -> "#{stem}_#{System.unique_integer([:positive])}.md" end)
    )
    |> Stream.map(&Path.join(dir, &1))
    |> Enum.find(&(not File.exists?(&1)))
  end

  defp record_cost(usage, elapsed_ms, session_id, opts) do
    attrs = %{
      source: :coordinator_session,
      session_id: session_id,
      task_id: nil,
      workspace_id: Keyword.get(opts, :workspace_id),
      step: :other,
      model: Map.get(usage || %{}, :model, "transcript_distillation"),
      provider: "arbiter",
      cost_usd: Map.get(usage || %{}, :cost_usd, 0.0),
      duration_ms: elapsed_ms,
      tokens_in: Map.get(usage || %{}, :tokens_in),
      tokens_out: Map.get(usage || %{}, :tokens_out),
      cache_creation_tokens: Map.get(usage || %{}, :cache_creation_tokens),
      cache_read_tokens: Map.get(usage || %{}, :cache_read_tokens),
      occurred_at: Keyword.get(opts, :now, DateTime.utc_now())
    }

    case Ash.create(Event, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("TranscriptDistillation cost record failed: #{inspect(reason)}")
        :ok
    end
  end
end
