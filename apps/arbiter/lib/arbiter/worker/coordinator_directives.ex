defmodule Arbiter.Worker.CoordinatorDirectives do
  @moduledoc """
  The unread coordinator mail for a task, rendered as a prompt block.

  `arb message send <task> <text>` only lands a row in the task's mailbox; a
  worker that never lists it (a resumed session replaying its old context, a
  fresh dispatch whose first move is the ticket) never sees the direction, and
  one that lists it may be unable to open the body. So the spawn paths put the
  unread coordinator messages straight into the prompt (bd-kxzrk9).

  Nothing is marked read here: the worker's own `arb inbox <task>` drains the
  queue as before, and an undelivered block simply shows up again on the next
  launch.
  """

  require Ash.Query

  alias Arbiter.Messages.Message

  @kinds [:info, :direction, :mailbox, :flag, :escalation]
  @limit 20

  @doc "Prompt block for `task_id`'s unread coordinator mail, or `\"\"` when there is none."
  @spec section(String.t() | nil) :: String.t()
  def section(task_id) when is_binary(task_id) and task_id != "" do
    case unread(task_id) do
      [] -> ""
      messages -> render(task_id, messages)
    end
  rescue
    # A prompt must still assemble if the mailbox read fails.
    _ -> ""
  end

  def section(_task_id), do: ""

  @spec unread(String.t()) :: [Message.t()]
  def unread(task_id) do
    refs = Message.coordinator_refs()

    Message
    |> Ash.Query.filter(to_ref == ^task_id and from_ref in ^refs and kind in ^@kinds)
    |> Message.for_reader(nil, :unread)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!()
  end

  defp render(task_id, messages) do
    entries =
      Enum.map_join(messages, "\n", fn m ->
        subject = if m.subject in [nil, ""], do: "", else: " — #{m.subject}"
        "--- message #{m.id} (#{m.kind})#{subject}\n#{String.trim(m.body || "")}\n"
      end)

    """

    UNREAD COORDINATOR DIRECTION for #{task_id} — #{length(messages)} message(s) sent
    to this task that you have not read yet. Act on them before anything else; they
    can supersede the description below. (`arb inbox #{task_id}` lists them again and
    marks them read.)

    #{entries}
    """
  end
end
