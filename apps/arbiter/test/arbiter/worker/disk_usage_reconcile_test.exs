defmodule Arbiter.Worker.DiskUsageReconcileTest do
  # DataCase (async: false → shared sandbox) so the worker process, which runs
  # under the DynamicSupervisor, reaches the same DB connection when it writes
  # the ledger row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  require Ash.Query

  # bd-be804c. `Worker.record_usage_event/3`'s disk fallback fires when a Claude
  # session dies before its terminal `result` event: stdout carried no tokens,
  # so the numbers are read back out of the CLI's own session JSONL. That path
  # used to hard-code `cost_usd: nil` because the moduledoc claimed the file had
  # no dollar figure — true of its `assistant` lines, false of the file, which
  # also carries periodic `cost-state` records. These tests pin both outcomes:
  # a file WITH `cost-state` now bills a real number, a file without still
  # reconciles tokens and says why its cost is null.

  defp events_for(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Seed `<config_dir>/projects/<slug>/<sid>.jsonl` with two deduped turns
  # (msg-1 is re-emitted, as the CLI really does) plus, optionally, a
  # `cost-state` record. Every line is stamped in the future so it lands inside
  # the live session's `since: started_at` window.
  defp write_session_jsonl!(config_dir, cwd, session_id, opts) do
    slug = ClaudeSessionFile.project_slug(cwd)
    dir = Path.join([config_dir, "projects", slug])
    File.mkdir_p!(dir)

    at = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()
    model = Keyword.get(opts, :model, "claude-opus-4-8")

    turns = [
      ~s({"type":"assistant","timestamp":"#{at}","message":{"id":"msg-1","model":"#{model}","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
      ~s({"type":"assistant","timestamp":"#{at}","message":{"id":"msg-1","model":"#{model}","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}),
      ~s({"type":"assistant","timestamp":"#{at}","message":{"id":"msg-2","model":"#{model}","usage":{"input_tokens":5,"output_tokens":200,"cache_read_input_tokens":2000,"cache_creation_input_tokens":60}}})
    ]

    cost_lines =
      case Keyword.get(opts, :cost_usd) do
        nil ->
          []

        cost ->
          start_ms =
            DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_unix(:millisecond)

          [
            ~s({"type":"cost-state","totalCostUSD":#{cost},"totalDuration":7000,"startTime":#{start_ms},"modelUsage":{"claude-opus-4-8":{"costUSD":#{cost}}}})
          ]
      end

    File.write!(
      Path.join(dir, session_id <> ".jsonl"),
      Enum.join(turns ++ cost_lines, "\n") <> "\n"
    )
  end

  # A session that emits only `init` (so the worker learns the session id) and
  # then exits — never a `result`. That is exactly the killed/crashed shape the
  # disk fallback exists for.
  defp run_dying_session!(task_id, config_dir, cwd, session_id) do
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-diskcost")

    init_event =
      Jason.encode!(%{
        "type" => "system",
        "subtype" => "init",
        "model" => "claude-opus-4-8",
        "session_id" => session_id
      })

    stdout_path = Path.join(cwd, "stdout-#{System.unique_integer([:positive])}.jsonl")
    File.write!(stdout_path, init_event <> "\n")

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", stdout_path],
        env: [{"CLAUDE_CONFIG_DIR", config_dir}]
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok
  end

  test "a crashed session's ledger row takes cost_usd from the file's cost-state record" do
    task_id = "bd-diskcost-#{System.unique_integer([:positive])}"
    session_id = "diskcost-#{System.unique_integer([:positive])}"
    cwd = tmp_dir!("diskcost-cwd")
    config_dir = tmp_dir!("diskcost-cfg")
    write_session_jsonl!(config_dir, cwd, session_id, cost_usd: 3.5)

    run_dying_session!(task_id, config_dir, cwd, session_id)

    assert [ev] = events_for(task_id)
    assert ev.tokens_in == 15, "tokens still come off the deduped assistant lines"
    assert ev.tokens_out == 300
    assert_in_delta ev.cost_usd, 3.5, 0.0000001
    assert ev.cost_note == nil
  end

  test "a file with no cost-state is priced from its tokens, and says so" do
    # Claude Code 2.1.270 writes no `cost-state` record at all, which left
    # every disk-reconciled worker row at `cost_usd: nil`. claude-opus-4-8 at
    # $5/$25 per MTok (cache write 1.25x, read 0.1x) over the deduped
    # in=15 out=300 cache_read=3000 cache_creation=110 buckets.
    task_id = "bd-diskcost-none-#{System.unique_integer([:positive])}"
    session_id = "diskcost-none-#{System.unique_integer([:positive])}"
    cwd = tmp_dir!("diskcost-none-cwd")
    config_dir = tmp_dir!("diskcost-none-cfg")
    write_session_jsonl!(config_dir, cwd, session_id, [])

    run_dying_session!(task_id, config_dir, cwd, session_id)

    assert [ev] = events_for(task_id)
    assert ev.tokens_in == 15
    assert_in_delta ev.cost_usd, 0.0097625, 0.0000001
    assert ev.cost_note =~ "estimated from tokens (no cost-state)"
  end

  test "a file with no cost-state and an unpriceable model still explains its null cost" do
    task_id = "bd-diskcost-unpriced-#{System.unique_integer([:positive])}"
    session_id = "diskcost-unpriced-#{System.unique_integer([:positive])}"
    cwd = tmp_dir!("diskcost-unpriced-cwd")
    config_dir = tmp_dir!("diskcost-unpriced-cfg")
    write_session_jsonl!(config_dir, cwd, session_id, model: "some-other-vendor-model")

    run_dying_session!(task_id, config_dir, cwd, session_id)

    assert [ev] = events_for(task_id)
    assert ev.tokens_in == 15
    assert ev.cost_usd == nil
    assert ev.cost_note == ClaudeSessionFile.no_cost_note()
  end

  # bd-agsn2b: the codex counterpart. A codex run killed before `turn.completed`
  # (only `thread.started` reached the stream) is reconciled from the rollout
  # `$CODEX_HOME/sessions/.../rollout-<ts>-<thread_id>.jsonl`.
  test "a killed codex run's tokens are reconciled from its rollout by thread id" do
    task_id = "bd-codexdisk-#{System.unique_integer([:positive])}"
    thread_id = "019f95ae-#{System.unique_integer([:positive])}"
    cwd = tmp_dir!("codexdisk-cwd")
    codex_home = tmp_dir!("codexdisk-home")

    dir = Path.join([codex_home, "sessions", "2026", "09", "29"])
    File.mkdir_p!(dir)
    at = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

    File.write!(
      Path.join(dir, "rollout-2026-09-29T10-00-00-#{thread_id}.jsonl"),
      ~s({"timestamp":"#{at}","type":"session_meta","payload":{"session_id":"#{thread_id}","timestamp":"#{at}"}}\n) <>
        ~s({"timestamp":"#{at}","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":400,"output_tokens":33}}}}\n)
    )

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-codexdisk")

    stdout_path = Path.join(cwd, "stdout.jsonl")

    File.write!(
      stdout_path,
      Jason.encode!(%{"type" => "thread.started", "thread_id" => thread_id}) <> "\n"
    )

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", stdout_path],
        provider: "codex",
        env: [{"CODEX_HOME", codex_home}]
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert [ev] = events_for(task_id)
    assert ev.tokens_in == 900
    assert ev.tokens_out == 33
    assert ev.cache_read_tokens == 400
    assert ev.raw["arb_usage_source"]["reconciled_from"] == "codex_rollout"
  end

  # G20 (bd-8yafoz): a *completed* codex run has stream tokens but no dollar
  # figure; the quota % its rollout's `rate_limits` moved by is the
  # cost-equivalent, recorded on the row's raw + cost_note.
  test "a completed codex run records the quota-window delta from its rollout rate_limits" do
    task_id = "bd-codexquota-#{System.unique_integer([:positive])}"
    thread_id = "019f95af-#{System.unique_integer([:positive])}"
    cwd = tmp_dir!("codexquota-cwd")
    codex_home = tmp_dir!("codexquota-home")

    dir = Path.join([codex_home, "sessions", "2026", "09", "29"])
    File.mkdir_p!(dir)
    t1 = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()
    t2 = DateTime.utc_now() |> DateTime.add(660, :second) |> DateTime.to_iso8601()

    tc = fn ts, p, s ->
      ~s({"timestamp":"#{ts}","type":"event_msg","payload":{"type":"token_count",) <>
        ~s("info":{"total_token_usage":{"input_tokens":5,"output_tokens":1}},) <>
        ~s("rate_limits":{"primary":{"used_percent":#{p},"window_minutes":300,"resets_at":1800000000},) <>
        ~s("secondary":{"used_percent":#{s},"window_minutes":10080,"resets_at":1800500000},"plan_type":"plus"}}})
    end

    File.write!(
      Path.join(dir, "rollout-2026-09-29T10-00-00-#{thread_id}.jsonl"),
      ~s({"timestamp":"#{t1}","type":"session_meta","payload":{"session_id":"#{thread_id}","timestamp":"#{t1}"}}\n) <>
        tc.(t1, 10.0, 20.0) <> "\n" <> tc.(t2, 13.5, 20.5) <> "\n"
    )

    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-codexquota")
    stdout_path = Path.join(cwd, "stdout.jsonl")

    File.write!(
      stdout_path,
      Jason.encode!(%{"type" => "thread.started", "thread_id" => thread_id}) <>
        "\n" <>
        Jason.encode!(%{
          "type" => "turn.completed",
          "usage" => %{"input_tokens" => 7, "output_tokens" => 2, "cached_input_tokens" => 1}
        }) <> "\n"
    )

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["cat", stdout_path],
        provider: "codex",
        env: [{"CODEX_HOME", codex_home}]
      )

    :ok = wait_until(fn -> events_for(task_id) != [] end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    assert [ev] = events_for(task_id)
    assert ev.tokens_in == 7
    assert is_nil(ev.cost_usd)
    assert ev.raw["arb_quota_delta"]["windows"]["primary"]["delta_percent"] == 3.5
    assert ev.raw["arb_quota_delta"]["windows"]["secondary"]["delta_percent"] == 0.5
    assert ev.cost_note =~ "3.5%"
  end

  defp wait_until(fun, timeout_ms \\ 3000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline, step_ms)
  end

  defp do_wait(fun, deadline, step_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until/3 timed out")

      true ->
        Process.sleep(step_ms)
        do_wait(fun, deadline, step_ms)
    end
  end
end
