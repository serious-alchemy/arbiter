defmodule Arbiter.Usage.CodexSessionFile do
  @moduledoc """
  Locate and read a Codex CLI probe's on-disk rollout JSONL, to backfill a
  `usage_events` row whose live capture (`Arbiter.Usage.Probe`) landed with
  `tokens_in`/`tokens_out: nil` before bd-96mn8i taught `Probe.parse/1`
  codex's `turn.completed` shape.

  ## On-disk layout (confirmed against installed codex-cli 0.153.4)

  The CLI writes one file per session at:

      $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<iso-ish-timestamp>-<session-id>.jsonl

  where `$CODEX_HOME` defaults to `~/.codex` when unset (the CLI's own
  default, mirrored here rather than reimplemented — see
  `Arbiter.Agents.Codex.Config`'s moduledoc for the auth side of the same
  convention). The directory triple is the UTC date the CLI opened the file,
  matching the `session_meta` line's own `timestamp` field.

  The first line of every file is a `session_meta` event carrying the wall
  clock the CLI process started:

      {"type":"session_meta","payload":{"session_id":"...","timestamp":"2026-09-21T16:23:15.991Z",...}}

  and — for a probe round-trip specifically — later lines carry the
  cumulative token totals as `token_count` events:

      {"type":"token_count","info":{"total_token_usage":{"input_tokens":11734,"cached_input_tokens":8960,"output_tokens":5,...},...}}

  `Arbiter.Agents.Codex.Stream.usage_fields/2` already knows this exact shape
  (it is the same `token_count` clause the *live* stream parser reads for
  pre-0.142.5 CLIs) — this module only adds the "find the right file for a
  ledger row" step and reuses that parser rather than re-deriving the field
  mapping a second time.

  ## Matching a `usage_events` row to a file

  A probe row carries no session id (per-dispatch probes are one-shot,
  `Arbiter.Usage.Probe.record/3` only fills `session_id` when the CLI
  reported one, and codex's `turn.completed` payload does not), so the only
  correlation available is time: a row's `occurred_at` is when `record/3`
  ran, just after the probe process exited, and `occurred_at - duration_ms`
  is (approximately) when the CLI process started — which is exactly what a
  rollout's `session_meta.timestamp` records. `find_for_probe/3` globs the
  UTC day directory (and the previous day, for a probe that straddled
  midnight) and picks the file whose `session_meta` timestamp is closest to
  that estimate, within a tolerance.
  """

  require Logger

  @type totals :: %{
          tokens_in: integer() | nil,
          tokens_out: integer() | nil,
          cache_read_tokens: integer() | nil,
          raw: map() | nil
        }

  @doc """
  The root directory the codex CLI writes session rollouts under.

  `$CODEX_HOME` when set (matching the CLI's own resolution), else
  `~/.codex`.
  """
  @spec home_dir() :: String.t()
  def home_dir do
    case System.get_env("CODEX_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.user_home!(), ".codex")
    end
  end

  @doc "The `sessions/` directory under `home_dir/0`."
  @spec sessions_dir() :: String.t()
  def sessions_dir, do: Path.join(home_dir(), "sessions")

  @doc """
  Every rollout `.jsonl` file under the UTC day directory for `date`, rooted
  at `sessions_dir` (defaults to `sessions_dir/0`; overridable so tests don't
  have to mutate `$CODEX_HOME` process-globally).
  Empty when the day has no rollouts (or the sessions dir doesn't exist).
  """
  @spec candidates_for_date(Date.t(), String.t()) :: [String.t()]
  def candidates_for_date(%Date{} = date, sessions_dir \\ sessions_dir()) do
    dir =
      Path.join([
        sessions_dir,
        pad4(date.year),
        pad2(date.month),
        pad2(date.day)
      ])

    Path.wildcard(Path.join(dir, "*.jsonl"))
  end

  @doc """
  Find the rollout file whose `session_meta.timestamp` is closest to a
  probe's estimated start time, within `tolerance_ms` (default 5000).

  `occurred_at` is the ledger row's own timestamp (when `record/3` ran,
  just after the probe exited) and `duration_ms` is the row's recorded
  duration; their difference estimates the CLI process's start, which is
  what `session_meta.timestamp` records. Returns `{:ok, path}` or
  `:not_found`.

  `:sessions_dir` in `opts` overrides `sessions_dir/0`, for tests.
  """
  @spec find_for_probe(DateTime.t(), integer() | nil, integer(), keyword()) ::
          {:ok, String.t()} | :not_found
  def find_for_probe(occurred_at, duration_ms, tolerance_ms \\ 5_000, opts \\ [])

  def find_for_probe(%DateTime{} = occurred_at, duration_ms, tolerance_ms, opts) do
    sessions_dir = Keyword.get(opts, :sessions_dir, sessions_dir())

    start_estimate =
      if is_integer(duration_ms),
        do: DateTime.add(occurred_at, -duration_ms, :millisecond),
        else: occurred_at

    [DateTime.to_date(start_estimate), DateTime.to_date(occurred_at)]
    |> Enum.uniq()
    |> Enum.flat_map(&candidates_for_date(&1, sessions_dir))
    |> Enum.uniq()
    |> Enum.map(&{&1, session_meta_timestamp(&1)})
    |> Enum.filter(fn {_path, ts} -> match?(%DateTime{}, ts) end)
    |> Enum.map(fn {path, ts} -> {path, abs(DateTime.diff(ts, start_estimate, :millisecond))} end)
    |> Enum.filter(fn {_path, diff_ms} -> diff_ms <= tolerance_ms end)
    |> Enum.min_by(fn {_path, diff_ms} -> diff_ms end, fn -> nil end)
    |> case do
      nil -> :not_found
      {path, _diff_ms} -> {:ok, path}
    end
  end

  @doc """
  Read a rollout file's `session_meta.timestamp` (the first line). `:error`
  when the file is missing, unreadable, or its first line doesn't decode to
  a `session_meta` event with a parseable timestamp.
  """
  @spec session_meta_timestamp(String.t()) :: DateTime.t() | :error
  def session_meta_timestamp(path) do
    with {:ok, line} <- first_line(path),
         {:ok, %{"type" => "session_meta", "payload" => %{"timestamp" => ts}}} <- decode(line),
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
      dt
    else
      _ -> :error
    end
  end

  @doc """
  Read the final `token_count` event's totals out of a rollout file, via
  `Arbiter.Agents.Codex.Stream.usage_fields/2` — the same field mapping the
  live stream parser uses. Later `token_count` lines are cumulative (see the
  moduledoc), so the last one in the file is the session's total. Returns
  `{:ok, totals}` (all fields `nil` when the file carries no `token_count`
  line at all) or `{:error, reason}` when the file itself can't be read.
  """
  @spec read_totals(String.t()) :: {:ok, totals()} | {:error, term()}
  def read_totals(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, last_token_count(io)}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Locate the rollout of codex thread `thread_id` under the codex home
  `home` (`<home>/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread-id>.jsonl`).

  The filename ends in the thread id the live stream's `thread.started` event
  reports (the worker's run `session_id`), so — unlike a probe, which has to
  correlate by time — a worker run is found exactly. Returns `{:ok, path}` or
  `:not_found` (blank input, pruned file, or an id that is not a plain
  token — it is spliced into a glob, so wildcard characters are refused).
  """
  @spec locate(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :not_found
  def locate(home, thread_id)
      when is_binary(home) and home != "" and is_binary(thread_id) and thread_id != "" do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, thread_id) do
      [home, "sessions", "*", "*", "*", "rollout-*#{thread_id}.jsonl"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.sort()
      |> List.last()
      |> case do
        nil -> :not_found
        path -> {:ok, path}
      end
    else
      :not_found
    end
  end

  def locate(_home, _thread_id), do: :not_found

  @doc """
  Token totals for thread `thread_id`, read from its on-disk rollout — the
  reconciliation source for a run killed before `turn.completed` reached the
  stream parser.

  `token_count` lines are cumulative per thread, and `codex exec resume`
  appends to the same file, so `since: %DateTime{}` subtracts the last totals
  recorded before that instant, leaving only this run's own consumption.
  Returns `{:ok, totals}` or `:not_found` when no rollout exists or it carries
  no `token_count` line.
  """
  @spec usage_for(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, totals()} | :not_found
  def usage_for(home, thread_id, opts \\ []) do
    since = Keyword.get(opts, :since)

    with {:ok, path} <- locate(home, thread_id),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        io |> token_counts() |> window(since)
      after
        File.close(io)
      end
    else
      _ -> :not_found
    end
  end

  @doc """
  The ChatGPT-plan quota a run consumed — Codex's cost-equivalent, since a
  plan-metered run has no dollar figure (G20 / bd-8yafoz).

  Every `token_count` line in a rollout carries the account's `rate_limits`
  at that instant: `primary` (the 5-hour session window) and `secondary`
  (the weekly window), each with `used_percent`, `window_minutes` and
  `resets_at`. The run's consumption is the last sample minus the last sample
  before `since:`. With no earlier sample (a fresh account/thread) the
  baseline is the run's own first sample, so the figure is a lower bound —
  flagged `baseline: "first_sample"`. A window whose `resets_at` moved
  mid-run was reset, so the delta is the post-reset usage alone, flagged
  `reset: true`.

  Backend-neutral: it only reads what the rollout carries, so a Codex run
  against a backend that reports no `rate_limits` (free tier, Ollama, another
  Responses-API server) gets `:not_found` rather than a fabricated figure.
  """
  @spec quota_delta_for(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, %{plan_type: String.t() | nil, windows: %{String.t() => map()}}} | :not_found
  def quota_delta_for(home, thread_id, opts \\ []) do
    since = Keyword.get(opts, :since)

    with {:ok, path} <- locate(home, thread_id),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        io |> rate_limit_samples() |> quota_window(since)
      after
        File.close(io)
      end
    else
      _ -> :not_found
    end
  end

  # ---- internals ---------------------------------------------------------

  defp rate_limit_samples(io) do
    io
    |> IO.stream(:line)
    |> Enum.flat_map(fn line ->
      with {:ok, event} <- decode(line),
           %{"rate_limits" => %{} = rl} <- token_count_payload(event) do
        [{parse_ts(event["timestamp"]), rl}]
      else
        _ -> []
      end
    end)
  end

  defp quota_window([], _since), do: :not_found

  defp quota_window(samples, since) do
    {_ts, last} = List.last(samples)

    before =
      case since do
        %DateTime{} ->
          samples
          |> Enum.filter(fn {ts, _} ->
            match?(%DateTime{}, ts) and DateTime.compare(ts, since) == :lt
          end)
          |> List.last()

        _ ->
          nil
      end

    {baseline_kind, {_, base}} =
      if before, do: {"before_run", before}, else: {"first_sample", hd(samples)}

    windows =
      for name <- ["primary", "secondary"],
          %{"used_percent" => now} when is_number(now) <- [last[name]],
          into: %{} do
        {name, window_delta(name, last[name], base[name], baseline_kind)}
      end

    if map_size(windows) == 0 do
      :not_found
    else
      {:ok, %{plan_type: last["plan_type"], windows: windows}}
    end
  end

  defp window_delta(_name, %{"used_percent" => now} = last, base, baseline_kind) do
    then_pct = if is_map(base), do: base["used_percent"]

    reset? =
      is_map(base) and base["resets_at"] != last["resets_at"] and not is_nil(last["resets_at"])

    delta =
      cond do
        reset? -> now
        is_number(then_pct) -> max(now - then_pct, 0)
        true -> now
      end

    %{
      delta_percent: Float.round(delta * 1.0, 2),
      used_percent: now,
      window_minutes: last["window_minutes"],
      baseline: baseline_kind,
      reset: reset?
    }
  end

  defp last_token_count(io) do
    io
    |> IO.stream(:line)
    |> Enum.reduce(%{tokens_in: nil, tokens_out: nil, cache_read_tokens: nil, raw: nil}, fn line,
                                                                                            acc ->
      case decode(line) do
        {:ok, event} ->
          case token_count_payload(event) do
            %{} = payload ->
              fields = Arbiter.Agents.Codex.Stream.usage_fields(payload, nil)

              %{
                tokens_in: Map.get(fields, :tokens_in, acc.tokens_in),
                tokens_out: Map.get(fields, :tokens_out, acc.tokens_out),
                cache_read_tokens: Map.get(fields, :cache_read_tokens, acc.cache_read_tokens),
                raw: Map.get(fields, :raw, acc.raw)
              }

            nil ->
              acc
          end

        :error ->
          acc
      end
    end)
  end

  # Every line on disk is wrapped in an envelope the live stream never sees:
  # `{"timestamp":..,"ordinal":..,"type":"event_msg","payload":{...the actual
  # event...}}` (confirmed live, installed codex-cli 0.153.4, against a real
  # rollout under `~/.codex/sessions/`; `session_meta` is the one exception —
  # it is *not* `event_msg`-wrapped, its own `type` is `session_meta` at the
  # top level, which `session_meta_timestamp/1` already relies on). Unwrap to
  # the inner event before handing it to `Codex.Stream.usage_fields/2`, which
  # knows the *unwrapped* `token_count` shape (it reads the live `--json`
  # stream, which carries no envelope at all).
  defp token_count_payload(%{"type" => "token_count"} = event), do: event

  defp token_count_payload(%{
         "type" => "event_msg",
         "payload" => %{"type" => "token_count"} = payload
       }),
       do: payload

  defp token_count_payload(_event), do: nil

  # `[{timestamp | nil, totals}]` for every token_count line, in file order.
  defp token_counts(io) do
    io
    |> IO.stream(:line)
    |> Enum.flat_map(fn line ->
      with {:ok, event} <- decode(line),
           %{} = payload <- token_count_payload(event) do
        fields = Arbiter.Agents.Codex.Stream.usage_fields(payload, nil)
        [{parse_ts(event["timestamp"]), fields}]
      else
        _ -> []
      end
    end)
  end

  defp window([], _since), do: :not_found

  defp window(entries, since) do
    {_ts, last} = List.last(entries)

    before =
      case since do
        %DateTime{} ->
          entries
          |> Enum.filter(fn {ts, _} ->
            match?(%DateTime{}, ts) and DateTime.compare(ts, since) == :lt
          end)
          |> List.last()

        _ ->
          nil
      end

    base = if before, do: elem(before, 1), else: %{}

    {:ok,
     %{
       tokens_in: delta(last, base, :tokens_in),
       tokens_out: delta(last, base, :tokens_out),
       cache_read_tokens: delta(last, base, :cache_read_tokens),
       raw: Map.get(last, :raw)
     }}
  end

  defp delta(last, base, key) do
    case Map.get(last, key) do
      n when is_number(n) -> max(n - (Map.get(base, key) || 0), 0)
      _ -> nil
    end
  end

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  defp first_line(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.read(io, :line) do
            :eof -> {:error, :empty}
            {:error, reason} -> {:error, reason}
            line -> {:ok, line}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp pad4(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")
  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
