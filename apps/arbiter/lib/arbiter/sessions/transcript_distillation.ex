defmodule Arbiter.Sessions.TranscriptDistillation do
  @moduledoc """
  Phase 14 (bd-avt4lt): Transcript distillation pass.
  A bounded pass over a session's archived transcript that emits memory candidates
  into the phase-13 promotion queue.
  """

  require Logger

  alias Arbiter.Loop.Discovery.ClaudeInvoker
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.TranscriptReplay
  alias Arbiter.Usage.Event

  @default_max_bytes 100_000
  @default_max_candidates 10
  @default_max_cost_usd 0.50

  @osc8 ~r/\e\]8;[^;\e\a]*;([^\e\a]*)(?:\e\\|\a)(.*?)\e\]8;;(?:\e\\|\a)/s
  @osc ~r/\e\][^\e\a]*(?:\e\\|\a)/
  @csi ~r/\e\[[0-9;?]*[ -\/]*[@-~]/

  @doc """
  Runs the distillation pass for `session_id`.

  Options:
    * `:max_bytes` — scope bound: how many trailing bytes of transcript to read (default 100kB).
    * `:max_candidates` — budget bound: maximum number of candidates to emit (default 10).
    * `:max_cost_usd` — budget bound: log warning if model spends more than this (default 0.50).
    * `:invoker` — model invoker function `(prompt, opts) -> {:ok, text, usage}`.
    * `:workspace_id` — for model attribution/quota.
  """
  def run(session_id, opts \\ []) when is_binary(session_id) do
    opts = Keyword.put_new(opts, :max_bytes, @default_max_bytes)

    case TranscriptReplay.read_tail(session_id, opts) do
      {:ok, %{data: data, start_offset: start_offset, end_offset: end_offset}}
      when byte_size(data) > 0 ->
        run_model(session_id, data, start_offset, end_offset, opts)

      {:ok, _} ->
        {:ok, []}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_model(session_id, transcript, start_offset, end_offset, opts) do
    started = System.monotonic_time(:millisecond)
    prompt = build_prompt(session_id, transcript)

    reply = invoke(prompt, opts)
    elapsed = System.monotonic_time(:millisecond) - started

    case reply do
      {:ok, text, usage} ->
        record_cost(usage, elapsed, session_id, opts)
        check_budget(usage, opts)

        max_candidates = Keyword.get(opts, :max_candidates, @default_max_candidates)

        candidates =
          text
          |> parse_candidates()
          |> validate_and_anchor_candidates(session_id, start_offset, end_offset)
          |> Enum.take(max_candidates)

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
    #{strip_ansi(transcript)}
    </transcript>
    """
  end

  defp strip_ansi(text) do
    text
    |> then(&Regex.replace(@osc8, &1, fn _, target, label -> "#{label} (#{target})" end))
    |> then(&Regex.replace(@osc, &1, ""))
    |> then(&Regex.replace(@csi, &1, ""))
    |> String.replace("\r", "")
  end

  defp parse_candidates(text) do
    Regex.scan(~r/```markdown\n(.*?)\n```/s, text)
    |> Enum.map(fn [_, content] -> content end)
  end

  defp validate_and_anchor_candidates(candidates, session_id, start_offset, end_offset) do
    candidates
    |> Enum.map(fn content ->
      fields = Frontmatter.fields(content)

      if valid_candidate?(fields) do
        turn_range = Map.get(fields, "turn_range")

        pairs = [
          {"source_transcript", session_id},
          {"turn_range", turn_range || "#{start_offset}-#{end_offset}"}
        ]

        Frontmatter.put(content, pairs)
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp valid_candidate?(fields) do
    has_name? = is_binary(fields["name"]) and fields["name"] != ""
    has_desc? = is_binary(fields["description"]) and fields["description"] != ""
    has_type? = is_binary(fields["type"]) and fields["type"] != ""

    has_name? and has_desc? and has_type?
  end

  defp write_candidates(session_id, candidates) do
    dir = Layout.memory_candidates_dir(session_id)
    File.mkdir_p!(dir)

    Enum.each(candidates, fn content ->
      fields = Frontmatter.fields(content)
      name = Map.get(fields, "name", "candidate_#{System.unique_integer([:positive])}")

      filename = sanitize_filename(name)
      path = free_name(dir, filename)

      File.write!(path, content)
    end)
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
    |> String.replace(~r/^[^a-zA-Z0-9]+/, "")
    |> then(fn s -> if s == "", do: "candidate", else: s end)
    |> String.slice(0, 197)
    |> Kernel.<>(".md")
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

  defp check_budget(usage, opts) do
    cost = Map.get(usage || %{}, :cost_usd, 0.0)
    max_cost = Keyword.get(opts, :max_cost_usd, @default_max_cost_usd)

    if max_cost && cost > max_cost do
      Logger.warning(
        "Transcript distillation exceeded budget: #{cost} USD > #{max_cost} USD limit"
      )
    end
  end

  defp record_cost(usage, elapsed_ms, session_id, opts) do
    usage = usage || %{}

    attrs = %{
      source: :coordinator_session,
      session_id: session_id,
      task_id: nil,
      workspace_id: Keyword.get(opts, :workspace_id),
      step: :other,
      model: usage[:model] || "transcript_distillation",
      provider: "claude",
      cost_usd: usage[:cost_usd] || 0.0,
      duration_ms: elapsed_ms,
      tokens_in: usage[:tokens_in],
      tokens_out: usage[:tokens_out],
      cache_creation_tokens: usage[:cache_creation_tokens],
      cache_read_tokens: usage[:cache_read_tokens],
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
