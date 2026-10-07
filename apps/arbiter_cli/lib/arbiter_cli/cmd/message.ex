defmodule ArbiterCli.Cmd.Message do
  @moduledoc """
  `arb message <verb>` — the inter-agent message queue: mailboxes + the
  coordinator's notification feed.

      arb message inbox  [--all | read <id> | clear | <task-id>]
                         the coordinator's mailbox (messages sent *up* the
                         chain); a `<task-id>` drains that task's unread
                         direction.
      arb message send   <recipient> <body> [--subject ...] [--task bd-x]
                         [--kind notification|completion|failure|escalation|info]
                         (--directive is a deprecated alias for --task)
                         send a message up (or across) the chain. The `from`
                         identity defaults to $ARB_FROM, falling back to "cli".
      arb message notify [--limit N]
                         the recent notification feed.

  As a shorthand, `arb message <task-id> <text>` (no verb) sends a
  `:direction` from the coordinator down to a running worker — the worker
  picks it up next time it runs `arb message inbox <task-id>`.
  """

  alias ArbiterCli.{ArgParser, Client, Cmd, Output, Workspace}

  @allowed_kinds ~w(notification completion failure escalation info)
  @default_kind "info"

  def run(argv) do
    case argv do
      ["inbox" | rest] -> Cmd.Inbox.run(rest)
      ["notify" | rest] -> Cmd.Notify.run(rest)
      ["send" | rest] -> send(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      # Shorthand: `arb message <task-id> <text>` → a coordinator direction.
      [task_id | [_ | _] = rest] -> direction(task_id, rest)
      [_task_id] -> Output.die("message requires text: `arb message <task-id> <text>`")
      [] -> Output.die("message requires a subcommand", usage_hint())
    end
  end

  # ---- send (was `arb msg`) ----------------------------------------------

  defp send(argv) do
    {opts, positional, mode} =
      ArgParser.parse(argv,
        command: "arb message send",
        strict: [subject: :string, task: :string, directive: :string, kind: :string]
      )

    case positional do
      [recipient | [_ | _] = words] ->
        send_msg(recipient, Enum.join(words, " "), opts, mode)

      [_recipient] ->
        Output.die("message send requires a body: `arb message send <recipient> <body>`")

      _ ->
        Output.die("message send requires: <recipient> <body>")
    end
  end

  defp send_msg(recipient, body, opts, mode) do
    case validate_kind(opts[:kind]) do
      {:ok, kind} ->
        task_ref = opts[:task] || opts[:directive]
        workspace_id = resolve_message_workspace(recipient, task_ref)

        payload =
          %{
            kind: kind,
            from_ref: from_identity(),
            to_ref: recipient,
            body: body,
            workspace_id: workspace_id
          }
          |> put_optional(:subject, opts[:subject])
          |> put_optional(:task_ref, task_ref)

        case Client.post("/api/messages", payload) do
          {:ok, message} -> emit_send(message, recipient, kind, mode)
          {:error, err} -> Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  defp validate_kind(nil), do: {:ok, @default_kind}
  defp validate_kind(k) when k in @allowed_kinds, do: {:ok, k}

  defp validate_kind(k),
    do: {:error, "invalid --kind #{inspect(k)} (allowed: #{Enum.join(@allowed_kinds, ", ")})"}

  defp from_identity, do: System.get_env("ARB_FROM") || "cli"

  defp put_optional(map, _key, val) when val in [nil, ""], do: map
  defp put_optional(map, key, val), do: Map.put(map, key, val)

  defp emit_send(message, _recipient, _kind, :json), do: IO.puts(Jason.encode!(message))
  defp emit_send(_message, recipient, kind, :text), do: IO.puts("Sent #{kind} to #{recipient}.")

  # ---- direction shorthand (was `arb message <task> <text>`) -------------

  # The one deliberate opt-out from strict flag parsing (bd-cqw11s): everything
  # after the task id is free text for the worker, so a word that starts with a
  # dash is body, not a flag. Only `--json` is peeled off.
  defp direction(task_id, words) do
    mode = Output.mode(words)
    text = words |> Output.drop_json() |> Enum.join(" ")
    workspace_id = resolve_message_workspace(task_id, task_id)

    body = %{
      kind: "direction",
      from_ref: "coordinator",
      to_ref: task_id,
      body: text,
      workspace_id: workspace_id
    }

    case Client.post("/api/messages", body) do
      {:ok, message} -> emit_direction(message, task_id, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_direction(message, _task_id, :json), do: IO.puts(Jason.encode!(message))
  defp emit_direction(_message, task_id, :text), do: IO.puts("Direction sent to #{task_id}.")

  # D-M-1: A message sent to a recipient task files under that recipient task's
  # workspace, not the CLI's default workspace. Check if recipient (or task_ref)
  # is a task on the server and use its workspace_id if so.
  defp resolve_message_workspace(recipient, task_ref) do
    target = recipient_task_candidate(recipient) || recipient_task_candidate(task_ref)

    case target && Client.get("/api/issues/" <> URI.encode(target)) do
      {:ok, %{"data" => %{"workspace_id" => ws_id}}} when is_binary(ws_id) and ws_id != "" ->
        ws_id

      {:ok, %{"workspace_id" => ws_id}} when is_binary(ws_id) and ws_id != "" ->
        ws_id

      _ ->
        Workspace.id_or_halt()
    end
  end

  defp recipient_task_candidate(nil), do: nil
  defp recipient_task_candidate(""), do: nil
  defp recipient_task_candidate("coordinator"), do: nil
  defp recipient_task_candidate("cli"), do: nil
  defp recipient_task_candidate("system"), do: nil
  defp recipient_task_candidate(target), do: target

  defp usage_hint do
    "verbs: inbox, send, notify"
  end
end
