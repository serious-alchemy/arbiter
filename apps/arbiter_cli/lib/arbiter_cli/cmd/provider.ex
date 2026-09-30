defmodule ArbiterCli.Cmd.Provider do
  @moduledoc """
  Provider pause controls (bd-5ef587), mirroring `arb scheduler pause`:

      arb provider pause <provider|account-ref> [--reason "…"] [--stop-running]
      arb provider resume <provider|account-ref>
      arb provider list                      — active pauses: who, when, why

  `<provider>` is `claude`, `codex` or `antigravity`; an account ref is an id,
  `provider:slug` or an unambiguous slug (`arb account list`).

  A paused provider/account is dropped from every routing decision — implementer,
  reviewer, failover, resume, fix and conflict passes — with the reason
  `paused`. Held or queued dispatches for it re-route if another candidate
  exists, else read `held — <provider> paused: <reason>`. Running workers keep
  running unless `--stop-running` is given. The pause persists across restarts.
  Coordinator only.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      case Output.drop_json(argv) do
        ["pause" | rest] ->
          pause(rest, Output.mode(argv))

        ["resume" | rest] ->
          resume(rest, Output.mode(argv))

        ["list" | _] ->
          list(Output.mode(argv))

        _ ->
          IO.puts(:stderr, "arb: unknown provider subcommand")
          IO.puts(:stderr, "Run `arb provider --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp pause(argv, mode) do
    {opts, rest, _} =
      ArgParser.parse_strict!(argv, "arb provider pause",
        strict: [reason: :string, stop_running: :boolean]
      )

    ref = ref!(rest, "pause")

    body = %{
      "ref" => ref,
      "reason" => Keyword.get(opts, :reason),
      "stop_running" => Keyword.get(opts, :stop_running, false)
    }

    case Client.post("/api/providers/pause", body) do
      {:ok, resp} ->
        if mode == :json do
          IO.puts(Jason.encode!(resp))
        else
          IO.puts("Paused #{ref}. It is dropped from every routing decision (reason: paused).")

          case resp["stopped"] do
            [_ | _] = ids -> IO.puts("Stopped running workers: #{Enum.join(ids, ", ")}")
            _ -> IO.puts("Running workers keep running (use --stop-running to stop them).")
          end
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp resume(argv, mode) do
    {_opts, rest, _} = ArgParser.parse_strict!(argv, "arb provider resume", strict: [])
    ref = ref!(rest, "resume")

    case Client.post("/api/providers/resume", %{"ref" => ref}) do
      {:ok, resp} ->
        if mode == :json, do: IO.puts(Jason.encode!(resp)), else: IO.puts("Resumed #{ref}.")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp list(mode) do
    case Client.get("/api/providers/paused") do
      {:ok, resp} ->
        if mode == :json do
          IO.puts(Jason.encode!(resp))
        else
          case resp["paused"] do
            [_ | _] = rows -> emit_paused(rows)
            _ -> IO.puts("No providers paused.")
          end
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp ref!([ref | _], _verb) when is_binary(ref), do: ref

  defp ref!(_, verb) do
    Output.die("arb provider #{verb}: a provider or account ref is required")
  end

  @doc "Print the paused-providers block (`arb quota`, `arb prime`); silent when none."
  def emit_paused([_ | _] = rows) do
    IO.puts("PAUSED providers (dropped from all routing):")

    Enum.each(rows, fn r ->
      IO.puts(
        "  #{r["label"] || r["target"]} — #{r["reason"] || "no reason given"} " <>
          "(by #{r["by"] || "unknown"}, #{r["at"] || "unknown time"})"
      )
    end)

    IO.puts("")
  end

  def emit_paused(_), do: :ok
end
