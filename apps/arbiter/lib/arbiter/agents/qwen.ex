defmodule Arbiter.Agents.Qwen do
  @moduledoc """
  Qwen Code (`qwen`) adapter implementing `Arbiter.Agents.Agent` (bd-1cm12v, Q2
  of the bd-3km00p epic), modelled on `Arbiter.Agents.Grok`.

  qwen is a Gemini-CLI fork with a Claude-shaped headless stream, so this adapter
  is mostly argv and environment; parsing rides on `Arbiter.Worker.ClaudeSession`
  with `Arbiter.Agents.Qwen.Stream` absorbing the qwen quirks (tool names, the
  missing `result` line on budget exits, unknown-vs-zero usage) and mapping exit
  codes to `Arbiter.Worker.StopReason`.

  ## Argv

      qwen -p <prompt> -o stream-json --yolo --bare --auth-type openai \\
        --max-session-turns N [-m model]

  `--yolo` is required headless: nobody can answer an approval prompt (the
  permission layer is not the boundary, see `docs/worker-security.md`). The flags
  are the ones `Arbiter.Test.QwenCli` runs against the fixture server; qwen's
  flags churn quickly, so re-verify them with the harness on every qwen upgrade
  (`docs/qwen-test-harness.md`). The whole thing runs under
  `sh -c 'exec "$@" < /dev/null'`, so stdin is closed.

  ## Prompt delivery

  A prompt that fits one argv element goes inline as `-p`. A larger one would
  overflow the kernel's per-argument limit (E2BIG), so it is written to a
  temp file and fed on **stdin** (`qwen` with no `-p` and a non-TTY stdin reads
  the prompt from stdin): `sh -c 'f="$1"; shift; exec "$@" < "$f"' sh <file> qwen ...`.
  `prompt_tmpfile/1` recovers the path so the worker unlinks it on exit.

  ## Environment

  `NO_COLOR` and `QWEN_CODE_SUPPRESS_YOLO_WARNING` are set, and inherited
  `OPENAI_*` variables are removed from the spawn so the server's own
  credentials never reach a worker. The endpoint (`opts[:endpoint]`, a map with
  `:base_url` / `:api_key`) and model are re-added as `OPENAI_BASE_URL`,
  `OPENAI_API_KEY` and `OPENAI_MODEL`. The per-worker HOME, settings and
  telemetry/update switches are `Qwen.ConfigDir` (Q3); the jail and deny mapping
  are `Qwen.Security` (Q5); provider registration and routing are Q6. Until Q5
  lands the adapter reports `security_enforced?/0` false and no write
  confinement.

  ## Completion and failure

  Completion is the terminal `result` line plus the exit code; the `arb done`
  sentinel comes from assistant text, as for every provider. Exit 0 is success;
  41/42/44/52/53/54/55 are mapped by `Arbiter.Agents.Qwen.Stream.stop_reason/1`.
  Budget exits 53/55 emit **no** `result` line, so usage is summed from the
  per-message usage and survives them.

  ## Usage (Q7)

  `usage_attrs/1` normalises the stream's usage (qwen's `input_tokens` includes
  cache reads), reconciles it with the session JSONL at `opts[:session_file]`
  (`Qwen.SessionFile`, which also survives a killed run), and prices it from the
  endpoint (`Qwen.Usage.price/2`; unmetered endpoints record `0.0`). A sustained
  429 retry loop is turned into a provider hold by `Qwen.RetryHold`.

  ## Session id, resume and nudge (Q8)

  Every spawn pre-assigns its session with `--session-id <uuid>` (`opts[:session_id]`,
  else a fresh one), so the id is known before qwen's `init` event and a run killed
  by a server restart can still be resumed and its chat JSONL found
  (`Qwen.SessionFile.locate/2`, archived by `Arbiter.Worker.SessionArchive`).

  `splice_prompt/2` swaps the prompt of a stashed argv. A resume
  (`["--resume", sid, prompt]`) adds `--resume sid`; a nudge (`[prompt]`) is also
  delivered via `--resume`, using the id the argv pre-assigned. qwen refuses
  `--session-id` together with `--resume`, so the former is dropped. The result
  is always the inline-prompt shape (the stdin tmpfile positional is removed).
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.Agents.Qwen.SessionFile
  alias Arbiter.Agents.Qwen.Stream, as: QwenStream
  alias Arbiter.Agents.Qwen.Usage
  alias Arbiter.Worker.ClaudeSession

  @done_regex ~r/(?:\A|\n)[^\p{L}\p{N}\n]*arb done[^\p{L}\p{N}]*\z/u

  # Linux's per-argument execve limit (see `Arbiter.Agents.Claude`).
  @max_prompt_argv_bytes 131_072

  @default_max_turns 60

  @prompt_tmp_prefix "arb_qwen_prompt_"

  @inline_prompt_script ~s(exec "$@" < /dev/null)
  @stdin_prompt_script ~s(f="$1"; shift; exec "$@" < "$f")

  @static_env [
    {"NO_COLOR", "1"},
    {"QWEN_CODE_SUPPRESS_YOLO_WARNING", "1"}
  ]

  # Credential / endpoint channels an inherited server env must not hand a
  # worker; `endpoint_env/1` re-adds whichever the dispatch means to.
  @endpoint_vars ~w(OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL)

  @impl true
  def provider, do: "qwen"

  @impl true
  def done_sentinel, do: @done_regex

  # No deny mapping or jail yet (Q5): do not claim a guarantee that is absent.
  @impl true
  def security_enforced?, do: false

  @impl true
  def write_confinement(_policy), do: :none

  @impl true
  def prepare(_workspace, _opts \\ []), do: :ok

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, qwen} <- resolve_executable() do
      flags = flags(opts)

      if byte_size(prompt) > @max_prompt_argv_bytes do
        with {:ok, tmp} <- write_prompt_tmpfile(prompt) do
          {:ok, ["sh", "-c", @stdin_prompt_script, "sh", tmp, qwen | flags]}
        end
      else
        {:ok, ["sh", "-c", @inline_prompt_script, "sh", qwen, "-p", prompt | flags]}
      end
    end
  end

  # Swap the prompt of a stashed `default_argv/2` invocation; see "Session id,
  # resume and nudge" in the moduledoc. `{:error, :no_print_slot}` for an argv
  # that is not one of ours (test fixtures / custom commands).
  @doc false
  @spec splice_prompt([String.t()], [String.t()]) :: {:ok, [String.t()]} | {:error, atom()}
  def splice_prompt(argv, insert) when is_list(argv) and is_list(insert) do
    with {:ok, qwen, args} <- split_argv(argv),
         {:ok, args} <- swap_prompt(args, insert) do
      {:ok, ["sh", "-c", @inline_prompt_script, "sh", qwen | args]}
    end
  end

  defp split_argv(["sh", "-c", @inline_prompt_script, "sh", qwen | args]), do: {:ok, qwen, args}

  defp split_argv(["sh", "-c", @stdin_prompt_script, "sh", tmp, qwen | args]) do
    if String.starts_with?(Path.basename(tmp), @prompt_tmp_prefix),
      do: {:ok, qwen, ["-p", "" | args]},
      else: {:error, :no_print_slot}
  end

  defp split_argv(_), do: {:error, :no_print_slot}

  # `-p` is found by index: a previously nudged/resumed argv carries
  # `--resume <sid>` in front of it, and the session id lives in whichever of
  # `--session-id` / `--resume` is present.
  defp swap_prompt(args, insert) do
    case Enum.find_index(args, &(&1 == "-p")) do
      nil ->
        {:error, :no_print_slot}

      idx ->
        flags = args |> List.delete_at(idx) |> List.delete_at(idx)
        {created, flags} = pop_flag(flags, "--session-id")
        {resumed, flags} = pop_flag(flags, "--resume")
        session_id = created || resumed

        case insert do
          ["--resume", sid, prompt] -> {:ok, ["--resume", sid, "-p", prompt | flags]}
          [prompt] when is_nil(session_id) -> {:ok, ["-p", prompt | flags]}
          [prompt] -> {:ok, ["--resume", session_id, "-p", prompt | flags]}
        end
    end
  end

  defp pop_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> {nil, args}
      idx -> {Enum.at(args, idx + 1), args |> List.delete_at(idx) |> List.delete_at(idx)}
    end
  end

  @doc """
  The stdin-delivery temp file of an argv built by `default_argv/2`, or `nil`
  for an inline-prompt argv. Lets the worker unlink it once the port exits.
  """
  @spec prompt_tmpfile([String.t()]) :: String.t() | nil
  def prompt_tmpfile(argv) when is_list(argv) do
    with ["sh", "-c", @stdin_prompt_script, "sh", path | _] <- argv,
         true <- String.starts_with?(Path.basename(path), @prompt_tmp_prefix) do
      path
    else
      _ -> nil
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    scrubbed = Enum.map(@endpoint_vars, &{&1, false})
    overrides = endpoint_env(opts)
    overridden = MapSet.new(overrides, &elem(&1, 0))

    Enum.reject(scrubbed, fn {k, _} -> MapSet.member?(overridden, k) end) ++
      @static_env ++ isolation_env(opts) ++ overrides
  end

  # The worker's own HOME / QWEN_HOME, read-only system settings and the
  # phone-home switches. A home that cannot be prepared still points at the
  # isolated path, never the operator's.
  defp isolation_env(opts) do
    case ConfigDir.env(opts) do
      {:ok, env} -> env
      {:error, _} -> ConfigDir.isolation_env(ConfigDir.path(opts), opts)
    end
  end

  defp endpoint_env(opts) do
    endpoint = Keyword.get(opts, :endpoint) || %{}

    [
      {"OPENAI_BASE_URL", Map.get(endpoint, :base_url)},
      {"OPENAI_API_KEY", Map.get(endpoint, :api_key)},
      {"OPENAI_MODEL", resolved_model(opts)}
    ]
    |> Enum.filter(fn {_, v} -> is_binary(v) and v != "" end)
  end

  @impl true
  def resolved_model(opts \\ []) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  # `ClaudeSession` reads the session-config keys (task_id, topic, done_regex,
  # line_cap, ...) off the same map, so start from the shape the worker builds.
  @impl true
  def init_session(opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil,
      endpoint: Keyword.get(opts, :endpoint),
      session_file: Keyword.get(opts, :session_file)
    }
    |> Map.merge(
      ClaudeSession.build_session_config(
        Keyword.get(opts, :task_id),
        nil,
        provider: provider(),
        model: Keyword.get(opts, :model),
        redact_values: []
      )
    )
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    session = Map.put_new(session, :provider, provider())
    next = ClaudeSession.handle_data(session, line <> "\n", true)

    prev_len = length(Map.get(session, :output_lines, []))
    added = next.output_lines |> Enum.take(length(next.output_lines) - prev_len) |> Enum.reverse()

    {Enum.map(added, &{&1, arms_done?(&1)}), next}
  end

  # Tool calls and results, the session summary lines and error text never arm
  # the sentinel (the session's own detection is exact; this is the display
  # approximation every adapter exposes).
  @non_arming_prefixes ["⏴ ", "⏵ ", "⚙ ", "qwen error: "]

  defp arms_done?(line), do: not Enum.any?(@non_arming_prefixes, &String.starts_with?(line, &1))

  @impl true
  def usage_attrs(session) do
    session
    |> ClaudeSession.usage_summary()
    |> Usage.normalize_stream()
    |> Usage.reconcile(SessionFile.read(Map.get(session, :session_file)))
    |> Usage.price(Map.get(session, :endpoint))
    |> Map.put(:provider, provider())
  end

  @doc "True when `status` is one of qwen's budget exits (53 turns, 55 tokens): no `result` line."
  @spec budget_exit?(term()) :: boolean()
  defdelegate budget_exit?(status), to: QwenStream

  # ---- internals ---------------------------------------------------------

  defp resolve_executable do
    case System.find_executable("qwen") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, {:executable_not_found, "qwen"}}
    end
  end

  defp flags(opts) do
    ["-o", "stream-json", "--yolo", "--bare", "--session-id", session_id(opts)] ++
      ["--auth-type", auth_type(opts)] ++
      ["--max-session-turns", Integer.to_string(max_turns(opts))] ++
      model_flag(opts)
  end

  defp session_id(opts) do
    case Keyword.get(opts, :session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp auth_type(opts) do
    case Keyword.get(opts, :auth_type) do
      t when is_binary(t) and t != "" -> t
      _ -> "openai"
    end
  end

  defp max_turns(opts) do
    case Keyword.get(opts, :max_turns) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_turns
    end
  end

  defp model_flag(opts) do
    case resolved_model(opts) do
      nil -> []
      model -> ["-m", model]
    end
  end

  defp write_prompt_tmpfile(prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        @prompt_tmp_prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".txt"
      )

    with :ok <- File.write(tmp, prompt, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600) do
      {:ok, tmp}
    else
      {:error, reason} -> {:error, {:prompt_tmpfile_failed, reason}}
    end
  end
end
