defmodule ArbiterCli.Cmd.Reopen do
  @moduledoc """
  `arb reopen <id>` — reopen a closed (or verifying) ticket.

  Wraps `POST /api/issues/:id/reopen`, which runs the `reopen` transition
  (`:closed` | `:verifying` → `:queued`): it clears `closed_at` and returns the
  ticket to the ready queue. `arb ticket update` never moves a ticket's state,
  so this dedicated verb is the supported path out of `:closed`.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket reopen", switches: @switches)

      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] -> id
          [] -> Output.die("reopen requires a ticket id")
          _ -> Output.die("reopen takes exactly one positional argument: the ticket id")
        end

      case Client.post("/api/issues/" <> id <> "/reopen", %{}) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(friendly_error(id, err))
      end
    end
  end

  # The transition refusal is a 422 whose top-level message is the generic
  # "validation failed"; the useful reason ("Cannot reopen a ticket that is
  # :queued: reopen moves :closed | :verifying → :queued.") lives in the
  # per-field details on `state`. Surface that reason so the user understands
  # the ticket simply isn't closed, rather than seeing an opaque failure.
  defp friendly_error(id, %Client.Error{status: 422} = err) do
    case state_error_message(err) do
      nil -> err
      msg -> "#{id} could not be reopened: #{msg}"
    end
  end

  defp friendly_error(_id, err), do: err

  defp state_error_message(%Client.Error{body: %{"details" => %{"errors" => errors}}})
       when is_list(errors) do
    Enum.find_value(errors, fn
      %{"field" => "state", "message" => msg} when is_binary(msg) -> msg
      _ -> nil
    end)
  end

  defp state_error_message(_), do: nil
end
