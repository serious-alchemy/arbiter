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
                         send a message up (or across) the chain. The recipient
                         must be `coordinator` or an existing task; the server
                         files the message under the RECIPIENT task's workspace
                         (`-w` may only restate it). The `from` identity is set
                         by the server from your token; $ARB_FROM / "cli" only
                         applies to an unauthenticated call.
      arb message notify [--limit N]
                         the recent notification feed.

  As a shorthand, `arb message <task-id> <text>` (no verb) sends a
  `:direction` from the coordinator down to a running worker — the worker
  picks it up next time it runs `arb message inbox <task-id>`. The first word
  must be an existing task: `arb message sned bd-1 hi` fails with "task sned
  not found" rather than posting to a mailbox called `sned`. The text is
  required and may not be empty.
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
        if opts[:directive], do: warn_directive_deprecated()
        task_ref = opts[:task] || opts[:directive]

        # No `workspace_id`: the server files the message under the recipient
        # task's workspace (the CLI's own default must never be stamped on it).
        payload =
          %{kind: kind, from_ref: from_identity(), to_ref: recipient, body: body}
          |> put_optional(:subject, opts[:subject])
          |> put_optional(:task_ref, task_ref)
          |> put_optional(:workspace, Workspace.selected_id())

        case Client.post("/api/messages", payload) do
          {:ok, message} -> emit_send(message, recipient, kind, mode)
          {:error, err} -> Output.die(err)
        end

      {:error, msg} ->
        Output.die(msg)
    end
  end

  defp warn_directive_deprecated do
    IO.puts(:stderr, "arb: note: `--directive` is deprecated; use `--task`.")
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

    if String.trim(text) == "" do
      Output.die("message requires text: `arb message <task-id> <text>`")
    end

    body =
      %{kind: "direction", from_ref: "coordinator", to_ref: task_id, body: text}
      |> put_optional(:workspace, Workspace.selected_id())

    case Client.post("/api/messages", body) do
      {:ok, message} -> emit_direction(message, task_id, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_direction(message, _task_id, :json), do: IO.puts(Jason.encode!(message))
  defp emit_direction(_message, task_id, :text), do: IO.puts("Direction sent to #{task_id}.")

  defp usage_hint do
    "verbs: inbox, send, notify"
  end
end
