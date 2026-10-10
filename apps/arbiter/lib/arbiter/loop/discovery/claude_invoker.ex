defmodule Arbiter.Loop.Discovery.ClaudeInvoker do
  @moduledoc """
  The default model invoker for `Arbiter.Loop.Discovery` (bd-4f6opo): one
  print-mode `claude` turn with **no tools, no MCP servers and no session
  history**, prompt on stdin, `stream-json` out so the reply's usage (model,
  tokens, cost) can be recorded against the pass.

  Shape borrowed from `Arbiter.Workflows.CodeReview.Checks`'s default invoker
  (stdin via a temp file — the ~20k-token slice can exceed Linux's per-argument
  limit — and `CLAUDE_CONFIG_DIR` pinned by `Arbiter.Agents.Claude.ConfigDir`
  so the call never inherits the operator's personal `~/.claude`), with the
  tool-less argv of `Arbiter.Quota.GrantRefresher`. It runs in a fresh empty
  directory so no `CLAUDE.md`/`AGENTS.md` is picked up as instructions.

  Optional config under `config :arbiter, :loop_discovery`:

    * `:model` — passed as `--model` (default: the CLI's own default).
    * `:timeout_s` — wall-clock cap, via coreutils `timeout` when it is on
      `PATH` (default 300).

  Per-call bounds a caller may pass in `invoke/2`'s opts (bd-avt4lt, used by
  `Arbiter.Sessions.TranscriptDistillation`), each applied only when given:

    * `:model` — overrides the configured model.
    * `:max_budget_usd` — the CLI's own `--max-budget-usd` spend cap.
    * `:max_output_tokens` — `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, the CLI's output
      ceiling per response.
  """

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.SpawnEnv

  @default_timeout_s 300

  @base_args [
    "--print",
    "--output-format",
    "stream-json",
    "--verbose",
    "--no-session-persistence",
    "--strict-mcp-config",
    "--tools",
    ""
  ]

  @doc """
  Send `prompt` and return `{:ok, text, usage}` or `{:error, reason}`.
  `opts[:workspace_id]` selects whose Claude credential the call uses.
  """
  @spec invoke(String.t(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  def invoke(prompt, opts) when is_binary(prompt) do
    case System.find_executable("claude") do
      nil -> {:error, {:executable_not_found, "claude"}}
      path -> run(path, prompt, opts)
    end
  end

  defp run(path, prompt, opts) do
    dir = Path.join(System.tmp_dir!(), "arb_loop_discover_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prompt_file = Path.join(dir, "prompt.txt")

    try do
      File.write!(prompt_file, prompt)
      shell = Enum.map_join(argv(path, opts), " ", &sh_quote/1) <> " < " <> sh_quote(prompt_file)
      extras = ConfigDir.env(Keyword.get(opts, :workspace_id)) ++ extra_env(opts)
      env = SpawnEnv.cmd_env(extras, "claude")

      case ReleaseEnv.cmd("sh", ["-c", shell], env: env, cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          parse_stream(output)

        {_output, 124} ->
          {:error, {:timeout, timeout_s()}}

        {output, code} ->
          case parse_stream(output) do
            {:ok, text, usage} -> {:ok, text, Map.put(usage, :is_error, true)}
            _ -> {:error, {:claude_failed, code, output |> String.trim() |> tail()}}
          end
      end
    after
      File.rm_rf(dir)
    end
  end

  defp argv(path, opts) do
    cmd = [path | args(opts)]

    case System.find_executable("timeout") do
      nil -> cmd
      t -> [t, Integer.to_string(timeout_s()) | cmd]
    end
  end

  @doc "The CLI arguments for one call, after the executable (see the moduledoc's opts)."
  @spec args(keyword()) :: [String.t()]
  def args(opts) do
    model =
      case Keyword.get(opts, :model) || config(:model) do
        m when is_binary(m) and m != "" -> ["--model", m]
        _ -> []
      end

    budget =
      case Keyword.get(opts, :max_budget_usd) do
        usd when is_number(usd) and usd > 0 -> ["--max-budget-usd", Float.to_string(usd * 1.0)]
        _ -> []
      end

    @base_args ++ model ++ budget
  end

  @doc "Environment the call adds for the opts it was given (see the moduledoc)."
  @spec extra_env(keyword()) :: [{String.t(), String.t()}]
  def extra_env(opts) do
    case Keyword.get(opts, :max_output_tokens) do
      n when is_integer(n) and n > 0 -> [{"CLAUDE_CODE_MAX_OUTPUT_TOKENS", Integer.to_string(n)}]
      _ -> []
    end
  end

  @doc """
  Parse `stream-json` output: the `result` event's text, token counts, cost,
  `subtype` (`"success"`, or why the CLI stopped, such as
  `"error_max_budget_usd"`) and `is_error`, and the `system/init` event's
  model. `{:error, :no_result_event}` when the stream never produced a
  result. A failed call can still say `"success"`: with no credential the CLI
  reports `is_error: true` and puts its error text where the reply would be.
  """
  @spec parse_stream(String.t()) :: {:ok, String.t(), map()} | {:error, :no_result_event}
  def parse_stream(output) when is_binary(output) do
    events =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{} = e} -> [e]
          _ -> []
        end
      end)

    model =
      Enum.find_value(events, fn
        %{"type" => "system", "subtype" => "init", "model" => m} -> m
        _ -> nil
      end)

    case Enum.find(events, &match?(%{"type" => "result"}, &1)) do
      nil ->
        {:error, :no_result_event}

      result ->
        u = result["usage"] || %{}

        {:ok, result["result"] || "",
         %{
           model: model,
           tokens_in: int(u["input_tokens"]),
           tokens_out: int(u["output_tokens"]),
           cache_creation_tokens: int(u["cache_creation_input_tokens"]),
           cache_read_tokens: int(u["cache_read_input_tokens"]),
           cost_usd: result["total_cost_usd"],
           duration_ms: result["duration_ms"],
           subtype: result["subtype"],
           is_error: result["is_error"] == true
         }}
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp tail(text) do
    if String.length(text) > 2000, do: String.slice(text, -2000..-1//1), else: text
  end

  defp timeout_s do
    case config(:timeout_s) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_s
    end
  end

  defp config(key), do: :arbiter |> Application.get_env(:loop_discovery, []) |> Keyword.get(key)

  defp sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
