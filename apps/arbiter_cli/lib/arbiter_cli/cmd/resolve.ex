defmodule ArbiterCli.Cmd.Resolve do
  @moduledoc """
  `arb review resolve <id> --amend "<reasoning>"` (also `arb ticket resolve`)

  Record your answer to a gate escalation (bd-4qjl0q): the ReviewGate hitting
  its round cap without converging, or the notes / commit gate spending its
  send-back budget. One decision flag, whose value is your reasoning:

      --accept-as-is "<why>"   ship it with the finding standing
      --amend        "<why>"   you change the requirement / direct the change
      --send-back    "<why>"   return it to the implementer
      --reject       "<why>"   abandon the work

      arb review resolve vs-acnaup --amend "heuristic need not be airtight; provenance tag instead"
      arb review resolve bd-2bydpv --send-back "worker skipped the notes write" --gate notes_gate

  Options:

      --gate <g>     review_gate (default) | notes_gate | commit_gate
      --round <n>    the ReviewGate round this answers (default: the latest)
      --actor <who>  who decided (default: coordinator)
      --json         print the recorded resolution as JSON

  The decision, reasoning, actor and timestamp are persisted against the ticket
  and returned by `review_gate_rounds_list`, so an override of a reviewer's
  standing finding is on record where the argument is — not only in a commit
  message. It records; it does not resume, merge or close anything.

  Wraps `POST /api/issues/:id/resolve`.
  """

  alias ArbiterCli.{Client, Output}

  @decisions [
    accept_as_is: "accept_as_is",
    amend: "amend",
    send_back: "send_back",
    reject: "reject"
  ]

  @switches [
    accept_as_is: :string,
    amend: :string,
    send_back: :string,
    reject: :string,
    gate: :string,
    round: :integer,
    actor: :string,
    json: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] -> id
          [] -> Output.die("resolve requires a ticket id", usage_hint())
          _ -> Output.die("resolve takes exactly one positional argument: the ticket id")
        end

      {decision, reasoning} = decision!(opts)

      body =
        %{"decision" => decision, "reasoning" => reasoning}
        |> put_opt("gate", opts[:gate])
        |> put_opt("round", opts[:round])
        |> put_opt("actor", opts[:actor])

      case Client.post("/api/issues/" <> id <> "/resolve", body) do
        {:ok, resolution} -> emit(resolution, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp decision!(opts) do
    case Enum.filter(@decisions, fn {flag, _} -> is_binary(opts[flag]) end) do
      [{flag, decision}] ->
        {decision, opts[flag]}

      [] ->
        Output.die(
          "resolve requires one of --accept-as-is / --amend / --send-back / --reject " <>
            "with your reasoning",
          usage_hint()
        )

      _ ->
        Output.die("resolve takes exactly one decision flag")
    end
  end

  defp put_opt(body, _key, nil), do: body
  defp put_opt(body, key, value), do: Map.put(body, key, value)

  defp emit(resolution, :json), do: Output.emit_json(resolution)

  defp emit(resolution, :text) do
    round =
      case resolution["round"] do
        nil -> ""
        n -> ", round #{n}"
      end

    IO.puts(
      "Recorded #{resolution["decision"]} on #{resolution["task_id"]} " <>
        "(#{resolution["gate"]}#{round}) by #{resolution["actor"]} at #{resolution["inserted_at"]}"
    )

    IO.puts("  #{resolution["reasoning"]}")
  end

  defp usage_hint do
    ~s(e.g. `arb review resolve bd-123 --amend "the finding is out of scope because ..."`)
  end
end
