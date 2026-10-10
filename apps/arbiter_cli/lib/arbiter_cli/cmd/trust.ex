defmodule ArbiterCli.Cmd.Trust do
  @moduledoc """
  `arb trust` — earned trust per subject (G18, `docs/design/guardrail-profiles.md`
  §6). A subject is the `provider/model` pair a worker runs, e.g.
  `antigravity/gemini-3.8-flash-low`.

      arb trust show [<subject>] [--json]
      arb trust promote <subject> --to <tier> --reason "..." [--json]
      arb trust confirm <subject> [--json]
      arb trust dismiss <subject> --reason "..." [--json]

  `show` (also bare `arb trust`) lists every subject's tier, record and
  promotion eligibility; with a subject, also its recent guardrail events, its
  history and any pending promotion proposal. The Loop folds these records on
  the canary ticker.

  `promote` is the **operator's** act, and the only way a subject moves up.
  The Loop proposes a promotion when the §6.3 thresholds hold (a
  `trust_promotion` proposal, which `arb loop apply` refuses), but only this
  command applies it. It first mints a short-lived coordinator token over the
  operator socket (peer-credential checked, refused for any process Arbiter
  spawned) and sends that — never `ARB_TOKEN`, which a coordinator session also
  holds. Run it from your own shell on the server host. There is no MCP twin:
  no MCP tool, at any tier, can promote. Tiers: quarantine, probation, trusted,
  privileged.

  `confirm` and `dismiss` are the coordinator's decision on an automatic
  suspension (a critical guardrail event suspends a subject on its own):
  `confirm` lets the demotion to quarantine stand, `dismiss` records a false
  positive and the subject's tier returns.
  """

  alias ArbiterCli.{ArgParser, Client, OperatorSocket, Output}

  # Long enough for the one request that follows.
  @proof_ttl 300

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        [] -> show([], mode)
        ["show" | tail] -> show(tail, mode)
        ["promote" | tail] -> promote(tail, mode)
        ["confirm" | tail] -> confirm(tail, mode)
        ["dismiss" | tail] -> dismiss(tail, mode)
        [other | _] -> Output.die("unknown `arb trust` subcommand: #{other}")
      end
    end
  end

  # ---- show ---------------------------------------------------------------------

  defp show(argv, mode) do
    {_opts, rest, _mode} = ArgParser.parse(argv, command: "arb trust show", switches: [])

    case rest do
      [] -> list(mode)
      [subject] -> one(subject, mode)
      _ -> Output.die("usage: arb trust show [<provider/model>]")
    end
  end

  defp list(mode) do
    case Client.get("/api/trust") do
      {:ok, %{"subjects" => _} = body} when mode == :json -> Output.emit_json(body)
      {:ok, %{"subjects" => []}} -> IO.puts("no trust records yet (the Loop folds them on the canary ticker)")
      {:ok, %{"subjects" => subjects}} -> print_list(subjects)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp one(subject, mode) do
    case Client.get("/api/trust", subject: subject) do
      {:ok, %{"subject" => detail}} when mode == :json -> Output.emit_json(detail)
      {:ok, %{"subject" => detail}} -> print_detail(detail)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp print_list(subjects) do
    IO.puts(
      Enum.join(
        [
          pad("SUBJECT", 44),
          pad("TIER", 11),
          pad("RUNS", 15),
          pad("EVENTS c/M/m", 13),
          pad("R1", 7),
          "STATUS"
        ],
        " "
      )
    )

    Enum.each(subjects, fn s ->
      r = s["record"] || %{}

      IO.puts(
        Enum.join(
          [
            pad(s["subject"], 44),
            pad(s["tier"] || "—", 11),
            pad("#{r["clean_runs"]}/#{r["runs"]} clean", 15),
            pad("#{r["critical_events"]}/#{r["major_events"]}/#{r["minor_events"]}", 13),
            pad(pct(r["round1_approve_rate"]), 7),
            status(s)
          ],
          " "
        )
      )
    end)
  end

  defp status(%{"suspended" => %{} = s} = subject),
    do: "SUSPENDED (#{s["kind"]}; treated as #{subject["effective_tier"]})"

  defp status(%{"pending" => [%{"to" => to} | _]}), do: "promotion to #{to} proposed"

  defp status(%{"eligibility" => %{"eligible_for" => to}}) when is_binary(to),
    do: "eligible for #{to}"

  defp status(%{"pinned" => true}), do: "pinned"
  defp status(_subject), do: ""

  defp print_detail(d) do
    r = d["record"] || %{}
    v = d["versions"] || %{}

    IO.puts(d["subject"])

    IO.puts(
      "  tier: #{d["tier"] || "— (no subject rule: guardrails off)"}" <>
        effective(d) <> "  pinned: #{if d["pinned"], do: "yes", else: "no"}"
    )

    if s = d["suspended"] do
      IO.puts(
        "  suspended since #{s["at"]}: #{s["kind"]} on run #{s["run_id"] || "?"} — the " <>
          "coordinator decides: arb trust confirm #{d["subject"]} | " <>
          "arb trust dismiss #{d["subject"]} --reason \"...\""
      )
    end

    IO.puts(
      "  record (#{r["window_days"]}d): #{r["clean_runs"]}/#{r["runs"]} clean runs on " <>
        "#{r["clean_tickets"]} ticket(s) across #{r["clean_repos"]} repo(s); events: " <>
        "#{r["critical_events"]} critical, #{r["major_events"]} major, #{r["minor_events"]} minor"
    )

    IO.puts(
      "  round-1 approve rate: #{pct(r["round1_approve_rate"])} over #{r["reviewed"]} reviewed"
    )

    IO.puts("  versions: harness #{v["harness"] || "—"}, model #{v["model"] || "—"}")
    print_eligibility(d["eligibility"] || %{})
    print_events(d["recent_events"] || [])
    print_pending(d["subject"], d["pending"] || [])
    print_history(d["history"] || [])
  end

  defp effective(%{"tier" => tier, "effective_tier" => tier}), do: ""
  defp effective(%{"effective_tier" => nil}), do: ""
  defp effective(%{"effective_tier" => eff}), do: " (effective: #{eff})"
  defp effective(_), do: ""

  defp print_eligibility(%{"to" => to} = e) when is_binary(to) do
    blocked = if e["blocked_by"], do: " (blocked: #{e["blocked_by"]})", else: ""
    verdict = if e["eligible_for"], do: " — eligible", else: ""

    IO.puts("  eligibility: #{e["from"]} → #{to}#{verdict}#{blocked}")
    if e["note"], do: IO.puts("    #{e["note"]}")

    Enum.each(e["criteria"] || [], fn c ->
      mark = if c["met"], do: "✓", else: "✗"
      detail = c["detail"] || "#{format(c["have"])} of #{format(c["need"])}"
      IO.puts("    #{mark} #{c["name"]}: #{detail}")
    end)
  end

  defp print_eligibility(%{"note" => note}), do: IO.puts("  eligibility: #{note}")
  defp print_eligibility(_), do: :ok

  defp print_events([]), do: IO.puts("  recent events: none")

  defp print_events(events) do
    IO.puts("  recent events:")

    Enum.each(events, fn e ->
      IO.puts(
        "    #{e["at"]} #{e["severity"]} #{e["kind"]} run #{e["run_id"] || "?"} " <>
          "ticket #{e["task_id"] || "?"}" <> if(e["detail"], do: " — #{e["detail"]}", else: "")
      )
    end)
  end

  defp print_pending(_subject, []), do: IO.puts("  pending proposal: none")

  defp print_pending(subject, pending) do
    IO.puts("  pending proposal:")

    Enum.each(pending, fn p ->
      IO.puts("    #{p["id"]} #{p["state"]} #{p["from"]} → #{p["to"]}: #{p["gist"]}")

      IO.puts(
        "    the operator applies it: arb trust promote #{subject} --to #{p["to"]} --reason \"...\""
      )
    end)
  end

  defp print_history([]), do: :ok

  defp print_history(history) do
    IO.puts("  history:")

    Enum.each(history, fn h ->
      extra = Enum.map_join(Map.drop(h, ~w(at action actor)), ", ", fn {k, v} -> "#{k}: #{format(v)}" end)
      IO.puts("    #{h["at"]} #{h["action"]} (#{h["actor"]})" <> if(extra != "", do: " #{extra}", else: ""))
    end)
  end

  # ---- promote (operator proof) ------------------------------------------------

  @promote_usage "usage: arb trust promote <provider/model> --to <tier> --reason \"...\""

  defp promote(argv, mode) do
    {opts, rest, _mode} =
      ArgParser.parse(argv,
        command: "arb trust promote",
        switches: [to: :string, reason: :string]
      )

    with [subject] <- rest,
         to when is_binary(to) and to != "" <- opts[:to],
         reason when is_binary(reason) <- opts[:reason],
         false <- String.trim(reason) == "" do
      body = %{"subject" => subject, "to" => to, "reason" => reason}

      with {:ok, %{"token" => proof}} <- OperatorSocket.mint(%{"ttl" => @proof_ttl}),
           {:ok, result} <- Client.post_with_token("/api/trust/promote", body, proof) do
        emit_decision(result, "promoted #{subject} to #{to}", mode)
      else
        {:error, %Client.Error{} = err} -> Output.die(err)
        {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      end
    else
      _ -> Output.die(@promote_usage)
    end
  end

  # ---- confirm / dismiss (the coordinator's own token) ------------------------------

  defp confirm(argv, mode) do
    {_opts, rest, _mode} = ArgParser.parse(argv, command: "arb trust confirm", switches: [])

    case rest do
      [subject] ->
        decide("/api/trust/confirm", %{"subject" => subject}, "confirmed the suspension of #{subject}", mode)

      _ ->
        Output.die("usage: arb trust confirm <provider/model>")
    end
  end

  defp dismiss(argv, mode) do
    {opts, rest, _mode} =
      ArgParser.parse(argv, command: "arb trust dismiss", switches: [reason: :string])

    case {rest, opts[:reason]} do
      {[subject], reason} when is_binary(reason) and reason != "" ->
        decide(
          "/api/trust/dismiss",
          %{"subject" => subject, "reason" => reason},
          "dismissed the suspension of #{subject}",
          mode
        )

      _ ->
        Output.die("usage: arb trust dismiss <provider/model> --reason \"...\"")
    end
  end

  defp decide(path, body, said, mode) do
    case Client.post(path, body) do
      {:ok, %{} = result} -> emit_decision(result, said, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_decision(result, _said, :json), do: Output.emit_json(result)

  defp emit_decision(result, said, :text) do
    subject = result["subject"] || %{}
    IO.puts("#{said} (tier now #{subject["effective_tier"] || subject["tier"] || "—"})")
  end

  # ---- formatting ---------------------------------------------------------------

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp pct(q) when is_number(q), do: "#{Float.round(q * 100 / 1, 1)}%"
  defp pct(_), do: "—"

  defp format(nil), do: "—"
  defp format(v) when is_float(v), do: Float.round(v, 3) |> to_string()
  defp format(v) when is_binary(v) or is_number(v) or is_atom(v), do: to_string(v)
  defp format(v), do: Jason.encode!(v)
end
