defmodule ArbiterCli.Cmd.Breaker do
  @moduledoc """
  Shared circuit-breaker subcommands (bd-5jr49o):

      arb breaker list [--workspace W] [--kind K] [--open]
                                        — show live breaker state plus the
                                          registry of every gated call site
      arb breaker reset <signature>     — close one tripped breaker
      arb breaker reset --all [--workspace W] [--kind K]
                                        — close every breaker in a scope
      arb breaker reset --auth-hold <provider>
                                        — clear a provider's auth hold
                                          (claude / codex / gemini)

  A breaker trips when the same signature — workspace + kind + normalised
  subject — fires more than K times inside its window. While open, the action
  behind it (filing a ticket, sending an escalation, re-dispatching a task) is
  suppressed, and the coordinator was paged exactly once naming the signature.

  `list` always prints the call-site registry, even on a freshly-restarted
  server where nothing has tripped yet, so "what is gated?" has an answer
  independent of runtime state.

  An **auth hold** (bd-21bmdh) is the dispatch hold a provider gets after N
  consecutive workers died on auth. It clears itself when the free credential
  check or the CredentialWatchdog probe next passes; `list` shows every open
  hold, and `reset --auth-hold` clears one by hand.

  Fix the underlying condition BEFORE resetting: a breaker whose cause is still
  live simply trips again, and in the meantime the flood resumes.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv,
          command: "arb breaker",
          switches: [
            workspace: :string,
            kind: :string,
            open: :boolean,
            all: :boolean,
            auth_hold: :string
          ]
        )

      case rest do
        ["list" | _] -> list(opts, mode)
        ["reset" | args] -> reset(args, opts, mode)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "arb: unknown breaker subcommand")
    IO.puts(:stderr, "Run `arb breaker --help` for usage.")
    Output.halt(2)
  end

  defp list(opts, mode) do
    params =
      []
      |> put_workspace(opts)
      |> put_flag(opts, :kind)
      |> then(fn p -> if opts[:open], do: [{:open_only, "true"} | p], else: p end)

    case Client.get("/api/breakers", params) do
      {:ok, body} ->
        if mode == :json, do: IO.puts(Jason.encode!(body)), else: print_list(body)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp reset(args, opts, mode) do
    body =
      cond do
        provider = opts[:auth_hold] ->
          %{provider: provider}

        opts[:all] ->
          %{all: true}
          |> put_workspace(opts)
          |> put_opt(opts, :kind)

        signature = List.first(args) ->
          %{signature: signature}

        true ->
          Output.die(
            "arb breaker reset needs a signature, or --all",
            "Run `arb breaker list` to see the signatures currently tripped."
          )
      end

    case Client.post("/api/breakers/reset", body) do
      {:ok, resp} ->
        if mode == :json, do: IO.puts(Jason.encode!(resp)), else: print_reset(resp)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp print_list(body) do
    breakers = body["breakers"] || []

    if breakers == [] do
      IO.puts("No circuit breakers have fired since the last restart.")
    else
      IO.puts("BREAKERS (#{body["open_count"]} open of #{length(breakers)})")

      Enum.each(breakers, fn b ->
        state = if b["open"], do: "OPEN", else: "closed"

        IO.puts(
          "  [#{state}] #{b["kind"]}  #{b["count"]}/#{b["limit"]} in " <>
            "#{div(b["window_ms"], 60_000)}m, #{b["suppressed"]} suppressed"
        )

        # Shell-quoted so the signature (which contains `|`, `::` between
        # structured subject components, and possibly an apostrophe — the
        # `:coordinator_escalation` breaker keys on free-text subject lines) can
        # be copied straight into `arb breaker reset ...` without the shell
        # re-parsing it.
        IO.puts("      #{shell_quote(b["signature"])}")
      end)
    end

    print_auth_holds(body["auth_holds"] || [])
    print_credential_watchdog(body["credential_watchdog"] || [])

    IO.puts("")
    IO.puts("REGISTERED CALL SITES")

    Enum.each(body["call_sites"] || [], fn s ->
      IO.puts(
        "  #{s["kind"]}  (K=#{s["limit"]} / #{div(s["window_ms"], 60_000)}m)  #{s["module"]}"
      )
    end)
  end

  defp print_reset(%{"auth_hold" => provider, "reset" => 0}) when is_binary(provider),
    do: IO.puts("No #{provider} auth hold was open.")

  defp print_reset(%{"auth_hold" => provider}) when is_binary(provider),
    do: IO.puts("Cleared the #{provider} auth hold.")

  defp print_reset(resp), do: IO.puts("Closed #{resp["reset"]} circuit breaker(s).")

  # bd-3kg53c: `CredentialWatchdog`'s own outstanding expiries — including a
  # `:periodic_probe`-only mark that never opened an `AuthHold` and so never
  # shows under AUTH HOLDS above. `--auth-hold <provider>` clears these too
  # (whether or not the hold itself was open), so the same hint line applies.
  defp print_credential_watchdog([]), do: :ok

  defp print_credential_watchdog(entries) do
    IO.puts("")
    IO.puts("CREDENTIAL WATCHDOG (adapters CredentialWatchdog still marks expired)")

    Enum.each(entries, fn e ->
      gate = if e["gated?"], do: "dispatch REFUSED", else: "escalated only"
      IO.puts("  [#{gate}] #{e["provider"]}")

      Enum.each(e["sources"] || [], fn s ->
        IO.puts("      #{s["source"]}: #{s["summary"]}")
      end)

      IO.puts("      arb breaker reset --auth-hold #{e["provider"]}")
    end)
  end

  defp print_auth_holds([]), do: :ok

  defp print_auth_holds(holds) do
    IO.puts("")
    IO.puts("AUTH HOLDS (dispatch refused per provider after consecutive auth deaths)")

    Enum.each(holds, fn h ->
      state =
        cond do
          h["open"] -> "OPEN"
          h["probation"] -> "probation"
          true -> "counting"
        end

      IO.puts("  [#{state}] #{h["provider"]}  #{h["deaths"]}/#{h["threshold"]} auth deaths")
      if h["open"], do: IO.puts("      arb breaker reset --auth-hold #{h["provider"]}")
    end)
  end

  # One POSIX-shell word. Mirrors `Arbiter.CircuitBreaker.Signature.shell_quote/1`
  # — the escript cannot depend on the server app at runtime, so the two are
  # kept in step by a test that asserts this output against the real one
  # (`breaker_test.exs`, "an apostrophe in a signature is printed as a runnable
  # shell word"). The `'\''` splice closes, escapes and reopens the quote.
  defp shell_quote(signature) when is_binary(signature),
    do: "'" <> String.replace(signature, "'", ~S('\'')) <> "'"

  defp shell_quote(other), do: inspect(other)

  # `--flag value` → a query param, when present.
  defp put_flag(params, opts, key) do
    case opts[key] do
      nil -> params
      value -> [{key, value} | params]
    end
  end

  # `--workspace` / `-w` / ARB_WORKSPACE, resolved to the workspace id.
  defp put_workspace(params, opts) do
    case ArbiterCli.Workspace.selected_id(opts[:workspace]) do
      nil -> params
      id when is_list(params) -> [{:workspace, id} | params]
      id -> Map.put(params, :workspace, id)
    end
  end

  defp put_opt(body, opts, key) do
    case opts[key] do
      nil -> body
      value -> Map.put(body, key, value)
    end
  end
end
