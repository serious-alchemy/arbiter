defmodule ArbiterCli.Cmd.Permit do
  @moduledoc """
  `arb ticket permit <id> <permission>` — grant a permission a worker asked for
  (or one you decide to give), or deny it:

      arb ticket permit  <id> <permission> [--reason "<why>"]
      arb ticket permit  <id> <permission> --deny --reason "<why the worker reads>"

  Wraps `POST /api/issues/:id/permission` (G15b, bd-lozakf). The server checks the
  binding's `grant_by` against the token's authority: a permission whose binding
  says `grant_by: operator` needs operator proof, so run this from the operator's
  own shell (a coordinator token is refused). A `network:` grant is live: the
  running worker's next connection to that host succeeds. An env, mount, tunnel
  or ssh grant reaches the worker at its next spawn (`arb worker resume`). A
  denial, with its `--reason`, is delivered to the worker's inbox. Both are
  recorded in `permission_events` with you as the actor.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [json: :boolean, deny: :boolean, reason: :string]

  @spec run([String.t()]) :: :ok
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _mode} =
      ArgParser.parse(argv, command: "arb ticket permit", switches: @switches)

    mode = if opts[:json], do: :json, else: :text
    {id, permission} = parse_positionals(rest)
    deny? = opts[:deny] == true

    if deny? and blank?(opts[:reason]),
      do: Output.die("--deny requires --reason: the worker reads it")

    body =
      %{"permission" => permission}
      |> put_if(deny?, "deny", true)
      |> put_if(not blank?(opts[:reason]), "reason", opts[:reason])

    case Client.post("/api/issues/" <> id <> "/permission", body) do
      {:ok, decided} -> emit(decided, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp parse_positionals([id, permission]), do: {id, permission}
  defp parse_positionals([]), do: Output.die("permit requires a ticket id and a permission")

  defp parse_positionals(_),
    do:
      Output.die(
        "permit takes exactly two positional arguments: the ticket id and the permission"
      )

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  defp emit(decided, :json), do: Output.emit_json(decided)

  defp emit(decided, :text) do
    IO.puts("#{decided["id"]}: #{decided["permission"]} #{decided["decision"]}")
    if decided["message"], do: IO.puts(decided["message"])

    case decided["pending_permissions"] do
      [_ | _] = pending -> IO.puts("still pending: " <> Enum.join(pending, ", "))
      _ -> :ok
    end

    :ok
  end
end
