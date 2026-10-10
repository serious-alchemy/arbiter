defmodule ArbiterCli.Cmd.Scheduler do
  @moduledoc """
  Board scheduler (autopilot) subcommand router:

      arb scheduler pause       — pause the autopilot (stop promoting Ready → Running)
      arb scheduler resume      — resume the autopilot
      arb scheduler status      — show the drain state and what is still in flight
      arb scheduler wait        — block until paused AND quiescent, then exit 0
          [--timeout SECS]      give up after SECS (default 3600) — exit 124
          [--interval SECS]     poll every SECS (default 10)

  A pause stops new *board* dispatches only. Work already under way — CI fix
  passes, MergeQueue conflict resolvers, ReviewGate rounds, explicit
  dispatches — keeps running so it can finish, and a server restart would
  kill it. `status` reports one of:

      running    — the autopilot is promoting; not a safe restart point
      draining   — paused, but work is still in flight (listed)
      quiescent  — paused and nothing in flight; safe to restart

  The restart workflow is `arb scheduler pause && arb scheduler wait`, then
  restart promptly: quiescence is a point in time, and a MergeQueue tick can
  start a resolver a moment later.

  `wait` exits 0 once quiescent, 2 if the scheduler is not paused (nothing to
  wait for — pause it first), 124 on timeout. Coordinator only.
  """

  alias ArbiterCli.{ArgParser, Client, Output, SchedulerState}

  @default_timeout_s 3600
  @default_interval_s 10

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      case Output.drop_json(argv) do
        [verb | rest] when verb in ["pause", "resume", "status"] ->
          {_opts, _rest, mode} =
            ArgParser.parse(rest ++ json_flag(argv),
              command: "arb scheduler #{verb}",
              switches: []
            )

          case verb do
            "pause" -> pause(mode)
            "resume" -> resume(mode)
            "status" -> status(mode)
          end

        ["wait" | wait_argv] ->
          wait(wait_argv, Output.mode(argv))

        _ ->
          IO.puts(:stderr, "arb: unknown scheduler subcommand")
          IO.puts(:stderr, "Run `arb scheduler --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp json_flag(argv), do: if("--json" in argv, do: ["--json"], else: [])

  defp pause(mode) do
    case Client.post("/api/scheduler/pause", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler paused. Work already in flight continues to completion.")
          IO.puts("Now: #{SchedulerState.headline(body)}")
          if SchedulerState.state(body) == "draining", do: emit_entries(body)
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp resume(mode) do
    case Client.post("/api/scheduler/resume", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler resumed. Autopilot is promoting Ready cards to Running.")
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp status(mode) do
    case SchedulerState.fetch() do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts("Board scheduler is #{SchedulerState.headline(body)}.")
          emit_changed(body)
          emit_capacity(body)
          emit_slots(body)
          emit_held(body)
          emit_entries(body)
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  # ---- wait ------------------------------------------------------------------

  defp wait(argv, mode) do
    {opts, _rest, _mode} =
      ArgParser.parse_strict!(argv, "arb scheduler wait",
        strict: [timeout: :integer, interval: :integer]
      )

    timeout_ms = max(Keyword.get(opts, :timeout, @default_timeout_s), 0) * 1000
    interval_ms = max(Keyword.get(opts, :interval, @default_interval_s), 1) * 1000
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll(%{mode: mode, deadline: deadline, interval_ms: interval_ms, last: nil})
  end

  defp poll(ctx) do
    case SchedulerState.fetch() do
      {:ok, body} -> step(SchedulerState.state(body), body, ctx)
      {:error, err} -> Output.die(err)
    end
  end

  defp step("quiescent", body, ctx),
    do: finish(body, ctx, 0, "Board scheduler is #{SchedulerState.headline(body)}.")

  defp step("running", body, ctx) do
    if ctx.mode == :json do
      IO.puts(Jason.encode!(body))
    else
      IO.puts(:stderr, "arb: error: the board scheduler is running — nothing to wait for")
      IO.puts(:stderr, "       hint: pause it first: `arb scheduler pause && arb scheduler wait`")
    end

    Output.halt(2)
  end

  defp step("unknown", body, ctx) do
    if ctx.mode == :json do
      IO.puts(Jason.encode!(body))
    else
      IO.puts(:stderr, "arb: error: #{SchedulerState.headline(body)}")
      IO.puts(:stderr, "       hint: upgrade the server, or check `arb worker list` by hand")
    end

    Output.halt(1)
  end

  defp step("draining", body, ctx) do
    ctx = report_progress(body, ctx)

    if System.monotonic_time(:millisecond) >= ctx.deadline do
      finish(body, ctx, 124, "Timed out: still #{SchedulerState.headline(body)}.")
    else
      ArbiterCli.Cmd.Start.sleep(ctx.interval_ms)
      poll(ctx)
    end
  end

  # Only print when the set of in-flight work changes, so a long drain
  # doesn't scroll the same list every interval.
  defp report_progress(body, %{mode: :text} = ctx) do
    fingerprint =
      Enum.map(SchedulerState.in_flight(body), &{&1["kind"], &1["task_id"], &1["registry_key"]})

    if fingerprint != ctx.last do
      IO.puts("Waiting: #{SchedulerState.headline(body)}")
      emit_entries(body)
    end

    %{ctx | last: fingerprint}
  end

  defp report_progress(_body, ctx), do: ctx

  defp finish(body, ctx, code, text) do
    if ctx.mode == :json, do: IO.puts(Jason.encode!(body)), else: IO.puts(text)
    if code != 0, do: Output.halt(code)
  end

  # bd-cl6zjn: when and by whom the pause state last changed, so a pause nobody
  # remembers making can be traced.
  defp emit_changed(%{"changed_at" => at, "changed_by" => by})
       when is_binary(at) or is_binary(by),
       do: IO.puts("Last changed: #{at || "unknown time"} by #{by || "unknown"}")

  defp emit_changed(_body), do: IO.puts("Last changed: unknown (no pause or resume recorded)")

  # DC5 (design §9): the admission mode, then one line per provider pool with its
  # budget and reason, the machines and the repo caps. A server that predates the
  # budgets sends none of these keys and prints none of it.
  defp emit_capacity(body) do
    emit_admission(body["admission"])
    emit_table("Providers", ~w(budget seats free why), body["budgets"], &pool_row/1)
    emit_table("Machines", ~w(cap live free), body["machines"], &machine_row/1)
    emit_table("Repos", ~w(cap runs), body["repos"], &repo_row/1)
  end

  defp emit_admission(%{"label" => label} = admission) do
    IO.puts("Admission: #{label}#{admission_note(admission)}")
  end

  defp emit_admission(_none), do: :ok

  defp admission_note(
         %{"agreement" => %{"agrees" => agrees, "comparable" => comparable} = a} = adm
       ) do
    since = if is_binary(a["since"]), do: " since #{String.slice(a["since"], 0, 10)}", else: ""

    " (the new walk agrees on #{agrees} of #{comparable} comparable decisions#{since}#{decides_note(adm)})"
  end

  defp admission_note(adm) do
    case decides_note(adm) do
      "" -> ""
      note -> " (" <> String.trim_leading(note, "; ") <> ")"
    end
  end

  defp decides_note(%{"decides" => false}), do: "; today's gate and caps still decide"
  defp decides_note(_), do: ""

  defp pool_row(pool) do
    {pool["label"] || pool["pool"],
     [cell(pool["budget"]), cell(pool["seats"]), cell(pool["free"])], pool["reason"]}
  end

  defp machine_row(m),
    do: {m["name"] || m["id"], [cell(m["cap"]), cell(m["live"]), cell(m["free"])], nil}

  defp repo_row(r),
    do: {r["label"] || to_string(r["repo"]), [cell(r["cap"]), cell(r["used"])], nil}

  defp cell(nil), do: "-"
  defp cell(value), do: to_string(value)

  defp emit_table(_title, _columns, rows, _row) when rows in [nil, []], do: :ok

  defp emit_table(title, columns, rows, row) do
    rows = Enum.map(rows, row)

    name_width =
      rows
      |> Enum.map(fn {name, _, _} -> String.length(name) end)
      |> Enum.max()
      |> max(String.length(title) - 2)

    header =
      Enum.map_join(columns, "", fn column -> String.pad_leading(column, widths(column)) end)

    IO.puts(String.pad_trailing(title, name_width + 2) <> header)

    Enum.each(rows, fn {name, cells, why} ->
      cells =
        columns
        |> Enum.zip(cells)
        |> Enum.map_join("", fn {column, cell} -> String.pad_leading(cell, widths(column)) end)

      IO.puts(
        "  " <>
          String.pad_trailing(name, name_width) <> cells <> if(why, do: "  " <> why, else: "")
      )
    end)
  end

  defp widths("why"), do: 5
  defp widths(_column), do: 10

  # bd-asxw4e: the dispatch cap's count, the same one the board header shows.
  defp emit_slots(%{"slots_used" => used} = body) when is_integer(used) do
    case Map.get(body, "slot_holders") do
      [_ | _] = ids -> IO.puts("Slots used: #{used} (#{Enum.join(ids, ", ")})")
      _ -> IO.puts("Slots used: #{used}")
    end
  end

  defp emit_slots(_body), do: :ok

  # bd-b2iigy: automatic resumes waiting on the primary's own worker cap — held,
  # not lost; they start in ticket-priority order as local slots free.
  defp emit_held(%{"held_local_capacity" => [_ | _] = held}) do
    ids = Enum.map(held, &(&1["task_id"] || "?"))
    IO.puts("Held: local capacity — #{length(ids)} resume(s) waiting for a local slot")
    Enum.each(ids, &IO.puts("  #{&1}  held: local capacity"))
  end

  defp emit_held(_body), do: :ok

  defp emit_entries(body) do
    Enum.each(SchedulerState.entry_lines(body), &IO.puts("  " <> &1))
  end
end
