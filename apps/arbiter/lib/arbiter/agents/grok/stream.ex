defmodule Arbiter.Agents.Grok.Stream do
  @moduledoc """
  The grok-specific half of the `--output-format streaming-messages-json`
  parser.

  grok's headless stream is "the Anthropic Messages API stream-json wire
  format" (bd-73uvlo, confirmed live in bd-7nbwix): `system/init`, `assistant` /
  `user` messages carrying `tool_use` / `tool_result` blocks, then a terminal
  `result`. `Arbiter.Worker.ClaudeSession` already parses that shape, so this
  module does not re-implement it: `normalize_event/1` rewrites the few places
  grok differs into the Claude vocabulary and the session carries on.

  The differences it absorbs:

    * **Tool names.** `run_terminal_command`, `write`, `search_replace`,
      `list_dir`, ... instead of `Bash`, `Write`, `Edit`, ... (`tool_name/1`).
      Mapped so the live activity line and the step ledger read the same as for
      any other provider.
    * **Typed, JSON-encoded tool results.** A `tool_result.content` is a JSON
      *string* like `{"type":"Bash","output":[79,110,...]}` whose `output` is a
      **byte array**, not text (`decode_tool_output/1`).
    * **`thinking` blocks** carry an opaque `signature`; they pass through
      untouched and the Claude parser already renders them (never arming the
      done sentinel).
    * **Unknown usage.** A failed run (bad model, not signed in) reports an
      all-zero `usage` and `$0.0` with `is_error: true`. That is "grok never
      reached inference", not "the run was free", so it is dropped rather than
      recorded as a real zero (`normalize_event/1`).

  ## Usage

  Every `assistant` message carries `message.usage`; `result.usage` carries the
  totals. In both, `input_tokens` is the **uncached** part only and cache reads
  are reported separately in `cache_read_input_tokens` (a quota total is
  `input + cache_read + output`; the ledger keeps them apart). Per-message usage
  is accumulated by `message_usage_fields/2` so a run killed before its
  `result` line (SIGTERM, 143) still leaves a usage record; the `result` totals
  then overwrite the running sums. `total_cost_usd` is notional on the free
  tier. `reasoning_tokens` is only in `grok usage <session>`, not the stream.
  """

  @doc """
  Ledger attrs for a grok run with its `total_cost_usd` treated as notional.

  The CLI reports xAI list price even when nothing was billed (free tier), and
  Arbiter has no signal for the account's tier, so a numeric `:cost_usd` is
  moved out of the spendable column into `:cost_note` ("notional — free tier").
  `cost_usd` becomes nil, so every `SUM(cost_usd)` total skips it. Other
  providers, and rows without a cost, pass through unchanged.
  """
  @spec mark_notional_cost(map()) :: map()
  def mark_notional_cost(%{provider: "grok", cost_usd: cost} = attrs) when is_number(cost) do
    price = :erlang.float_to_binary(cost * 1.0, decimals: 6)
    note = "notional — free tier: $#{price} list price, not billed"

    %{attrs | cost_usd: nil, cost_note: join_note(Map.get(attrs, :cost_note), note)}
  end

  def mark_notional_cost(attrs), do: attrs

  defp join_note(existing, note) when is_binary(existing) and existing != "",
    do: existing <> "; " <> note

  defp join_note(_, note), do: note

  # grok built-in -> the Claude tool it behaves like. Anything not listed (MCP
  # tools, future built-ins) keeps its own name, which the activity line shows.
  @tool_names %{
    "run_terminal_command" => "Bash",
    "write" => "Write",
    "search_replace" => "Edit",
    "read_file" => "Read",
    "grep" => "Grep",
    "list_dir" => "LS",
    "todo_write" => "TodoWrite",
    "spawn_subagent" => "Task",
    "web_search" => "WebSearch",
    "web_fetch" => "WebFetch"
  }

  @ledger_keys [
    {"input_tokens", :tokens_in},
    {"output_tokens", :tokens_out},
    {"cache_read_input_tokens", :cache_read_tokens},
    {"cache_creation_input_tokens", :cache_creation_tokens}
  ]

  @doc "The Claude-vocabulary name for a grok tool name (unknown names pass through)."
  @spec tool_name(String.t()) :: String.t()
  def tool_name(name) when is_binary(name), do: Map.get(@tool_names, name, name)

  @doc """
  Rewrite one decoded grok stream event into the shape `ClaudeSession` expects.
  Events with nothing grok-specific in them are returned unchanged.
  """
  @spec normalize_event(map()) :: map()
  def normalize_event(
        %{"type" => "assistant", "message" => %{"content" => content} = message} = e
      )
      when is_list(content) do
    %{e | "message" => %{message | "content" => Enum.map(content, &normalize_assistant_block/1)}}
  end

  def normalize_event(%{"type" => "user", "message" => %{"content" => content} = message} = e)
      when is_list(content) do
    %{e | "message" => %{message | "content" => Enum.map(content, &normalize_result_block/1)}}
  end

  def normalize_event(%{"type" => "result", "is_error" => true} = e) do
    if zero_usage?(e["usage"]),
      do: Map.drop(e, ["usage", "total_cost_usd", "modelUsage"]),
      else: e
  end

  def normalize_event(event), do: event

  defp normalize_assistant_block(%{"type" => "tool_use", "name" => name} = block),
    do: %{block | "name" => tool_name(name)}

  defp normalize_assistant_block(block), do: block

  defp normalize_result_block(%{"type" => "tool_result", "content" => content} = block)
       when is_binary(content),
       do: %{block | "content" => decode_tool_output(content)}

  defp normalize_result_block(block), do: block

  # An absent usage map is as unknown as an all-zero one.
  defp zero_usage?(%{} = usage),
    do: Enum.all?(@ledger_keys, fn {wire, _} -> Map.get(usage, wire) in [0, nil] end)

  defp zero_usage?(_), do: true

  @doc """
  Turn a grok `tool_result.content` string into display text.

  A `Bash` result's `output` byte array is decoded as UTF-8 (invalid bytes are
  replaced, never raised on); a `ListDir` result yields its listing. Plain text
  and every other typed result (`SearchReplace`, ...) come back unchanged.
  """
  @spec decode_tool_output(String.t()) :: String.t()
  def decode_tool_output(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"type" => "Bash", "output" => bytes}} when is_list(bytes) ->
        bytes_to_text(bytes, content)

      {:ok, %{"type" => "Bash", "output" => text}} when is_binary(text) ->
        text

      {:ok, %{"type" => "ListDir", "Content" => %{"content" => listing}}}
      when is_binary(listing) ->
        listing

      _ ->
        content
    end
  end

  defp bytes_to_text(bytes, fallback) do
    if Enum.all?(bytes, &(is_integer(&1) and &1 in 0..255)) do
      bytes |> :erlang.list_to_binary() |> String.replace_invalid()
    else
      fallback
    end
  end

  @doc """
  Usage fields for an `assistant` message, added onto `usage_so_far` (the
  session's `:usage` map). Returns `%{}` when the message carries no usage.
  Keys are the ledger's: `tokens_in` (uncached), `tokens_out`,
  `cache_read_tokens`, `cache_creation_tokens`.
  """
  @spec message_usage_fields(map(), map()) :: map()
  def message_usage_fields(%{"message" => %{"usage" => %{} = usage}}, usage_so_far) do
    for {wire, key} <- @ledger_keys, is_number(usage[wire]), into: %{} do
      {key, Map.get(usage_so_far, key, 0) + usage[wire]}
    end
  end

  def message_usage_fields(_event, _usage_so_far), do: %{}

  @doc """
  The `errors[]` of an error `result`, as transcript lines. The Claude result
  summary line carries no error text, and grok reports "Not signed in" and the
  like only here, so without these lines `StopReason.classify/3` has nothing to
  read.
  """
  @spec error_lines(map()) :: [String.t()]
  def error_lines(%{"type" => "result", "errors" => errors}) when is_list(errors) do
    errors
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, "\n"))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&("grok error: " <> &1))
  end

  def error_lines(_event), do: []
end
