defmodule Arbiter.Agents.Qwen.Stream do
  @moduledoc """
  The qwen-specific half of the `qwen -o stream-json` parser (bd-1cm12v, Q2 of
  the bd-3km00p qwen epic).

  qwen's headless stream uses Claude's envelopes (`system/init`, `assistant` /
  `user` messages with `tool_use` / `tool_result` blocks, a terminal `result`),
  so `Arbiter.Worker.ClaudeSession` parses it and this module only absorbs the
  differences, the same split as `Arbiter.Agents.Grok.Stream`.

  The fixtures under `test/fixtures/qwen` are hand-authored from the documented
  schema, not captured from a live run (no qwen binary or hosted endpoint was
  available); re-record them per `docs/qwen-test-harness.md`.

  ## Quirks absorbed

    * **Tool names.** `run_shell_command`, `read_file`, `write_file`, `replace`,
      ... instead of `Bash`, `Read`, `Write`, `Edit` (`tool_name/1`).
    * **Init version key.** `qwen_code_version`, not `claude_code_version`; it is
      copied across so the trust record's harness version is populated.
    * **Unknown vs zero usage.** A run that never reached inference (bad model,
      endpoint down) reports an all-zero `usage` with `is_error: true`; that is
      "unknown", so it is dropped rather than recorded as a free run.
    * **Error text.** An error `result` carries it in an `error` object (or
      `errors[]`), which the Claude summary line omits (`error_lines/1`).
    * **Budget exits emit no `result` line.** A run stopped by qwen's turn or
      token budget (exit 53 / 55) ends the stream after its last assistant
      message. Nothing waits for a `result`: usage is summed per assistant
      message (`message_usage_fields/2`) so the record survives, and the exit
      status alone classifies the stop (`stop_reason/1`).

  ## Usage

  `usage.input_tokens` / `output_tokens` / `cache_read_input_tokens` are taken as
  reported. Whether qwen's `input_tokens` already includes the cached part, and
  the reconcile against the session JSONL, belong to the usage task (Q7); the
  raw figures are kept apart so that task can decide.

  ## Exit codes

  | exit | meaning | category |
  | --- | --- | --- |
  | 41 | authentication failed | `:auth_expired` |
  | 42 | invalid input (prompt/flags) | `:crashed` |
  | 44 | sandbox error | `:crashed` |
  | 52 | invalid configuration | `:crashed` |
  | 53 | turn budget exhausted (`--max-session-turns`), no `result` | `:exited_without_done` |
  | 54 | tool execution error | `:crashed` |
  | 55 | token/session budget exhausted, no `result` | `:exited_without_done` |

  A budget stop is `:exited_without_done` on purpose: the worktree holds real
  work and the resume path ("you stopped early, carry on") is the right
  response; it is not an account quota (no provider hold). Exit 0, 1 and signal
  deaths are left to the generic classifier.
  """

  alias Arbiter.Worker.StopReason

  @tool_names %{
    "run_shell_command" => "Bash",
    "read_file" => "Read",
    "write_file" => "Write",
    "replace" => "Edit",
    "edit" => "Edit",
    "list_directory" => "LS",
    "glob" => "Glob",
    "grep_search" => "Grep",
    "search_file_content" => "Grep",
    "todo_write" => "TodoWrite",
    "task" => "Task",
    "web_fetch" => "WebFetch",
    "web_search" => "WebSearch"
  }

  @ledger_keys [
    {"input_tokens", :tokens_in},
    {"output_tokens", :tokens_out},
    {"cache_read_input_tokens", :cache_read_tokens},
    {"cache_creation_input_tokens", :cache_creation_tokens}
  ]

  @budget_exits [53, 55]

  @doc "The Claude-vocabulary name for a qwen tool name (unknown names pass through)."
  @spec tool_name(String.t()) :: String.t()
  def tool_name(name) when is_binary(name), do: Map.get(@tool_names, name, name)

  @doc """
  Rewrite one decoded qwen stream event into the shape `ClaudeSession` expects.
  Events with nothing qwen-specific in them are returned unchanged.
  """
  @spec normalize_event(map()) :: map()
  def normalize_event(%{"type" => "system", "subtype" => "init", "qwen_code_version" => v} = e),
    do: Map.put_new(e, "claude_code_version", v)

  def normalize_event(
        %{"type" => "assistant", "message" => %{"content" => content} = message} = e
      )
      when is_list(content) do
    %{e | "message" => %{message | "content" => Enum.map(content, &normalize_block/1)}}
  end

  def normalize_event(%{"type" => "result", "is_error" => true} = e) do
    if zero_usage?(e["usage"]), do: Map.drop(e, ["usage", "total_cost_usd"]), else: e
  end

  def normalize_event(event), do: event

  defp normalize_block(%{"type" => "tool_use", "name" => name} = block),
    do: %{block | "name" => tool_name(name)}

  defp normalize_block(block), do: block

  defp zero_usage?(%{} = usage),
    do: Enum.all?(@ledger_keys, fn {wire, _} -> Map.get(usage, wire) in [0, nil] end)

  defp zero_usage?(_), do: true

  @doc """
  Usage fields for an `assistant` message, added onto `usage_so_far` (the
  session's `:usage` map); `%{}` when the message carries none. The `result`
  totals overwrite these sums when a `result` line arrives.
  """
  @spec message_usage_fields(map(), map()) :: map()
  def message_usage_fields(%{"message" => %{"usage" => %{} = usage}}, usage_so_far) do
    for {wire, key} <- @ledger_keys, is_number(usage[wire]), into: %{} do
      {key, Map.get(usage_so_far, key, 0) + usage[wire]}
    end
  end

  def message_usage_fields(_event, _usage_so_far), do: %{}

  @doc """
  The error text of an error `result` as transcript lines, so
  `StopReason.classify/3` has something to read (the Claude summary line omits it).
  """
  @spec error_lines(map()) :: [String.t()]
  def error_lines(%{"type" => "result"} = event) do
    texts =
      case {event["error"], event["errors"]} do
        {%{"message" => m}, _} when is_binary(m) -> [m]
        {m, _} when is_binary(m) -> [m]
        {_, errors} when is_list(errors) -> Enum.filter(errors, &is_binary/1)
        _ -> []
      end

    texts
    |> Enum.flat_map(&String.split(&1, "\n"))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&("qwen error: " <> &1))
  end

  def error_lines(_event), do: []

  @doc "True for the exit statuses that mean qwen hit a budget (turns / tokens)."
  @spec budget_exit?(term()) :: boolean()
  def budget_exit?(status), do: status in @budget_exits

  @doc """
  The `StopReason` for a qwen exit status in the table above, or `nil` for an
  exit the generic classifier should decide (0, 1, signals, unknown codes).
  """
  @spec stop_reason(integer() | nil) :: StopReason.t() | nil
  def stop_reason(41) do
    reason(
      41,
      :auth_expired,
      "qwen could not authenticate against its endpoint (exit 41)",
      "Check the endpoint's API key / base URL for this account, then re-dispatch."
    )
  end

  def stop_reason(42) do
    reason(
      42,
      :crashed,
      "qwen rejected its input (exit 42): bad prompt or flags",
      "A harness argv/prompt bug, not the task. Check the spawn argv, then re-dispatch."
    )
  end

  def stop_reason(44) do
    reason(
      44,
      :crashed,
      "qwen's own sandbox failed to start (exit 44)",
      "qwen runs with its sandbox off under the Arbiter jail; check the settings the worker was given."
    )
  end

  def stop_reason(52) do
    reason(
      52,
      :crashed,
      "qwen rejected its configuration (exit 52)",
      "The worker's qwen settings file is invalid. Check it, then re-dispatch."
    )
  end

  def stop_reason(53) do
    reason(
      53,
      :exited_without_done,
      "qwen hit its turn budget (exit 53, --max-session-turns) before finishing; the stream has no result line",
      "The worktree holds the work so far: resume the session with a nudge, or raise max_turns."
    )
  end

  def stop_reason(54) do
    reason(
      54,
      :crashed,
      "a qwen tool execution failed fatally (exit 54)",
      "Check the transcript tail for the failing tool, then re-dispatch."
    )
  end

  def stop_reason(55) do
    reason(
      55,
      :exited_without_done,
      "qwen hit its token budget (exit 55) before finishing; the stream has no result line",
      "The worktree holds the work so far: resume the session with a nudge, or raise the budget."
    )
  end

  def stop_reason(_status), do: nil

  defp reason(status, category, summary, remediation) do
    %StopReason{
      category: category,
      summary: summary,
      remediation: remediation,
      exit_status: status,
      signal: nil
    }
  end
end
