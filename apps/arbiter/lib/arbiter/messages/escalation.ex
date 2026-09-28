defmodule Arbiter.Messages.Escalation do
  @moduledoc """
  The one door an escalation goes through (ticket lifecycle 6/13, bd-8if9zt).

  `post/1` writes an addressed `:escalation` to the coordinator's mailbox with
  a typed kind (`Arbiter.Messages.EscalationKind`), and:

    * **dedupes a ticket-scoped kind by `(kind, ticket)`.** While an
      escalation of the same kind about the same ticket is still open
      (uncleared), a repeat refreshes that row's subject and body instead of
      adding a second one — whatever its subject text says. A cleared or
      resolved row no longer suppresses a repeat.
    * **records the ticket's attention cause** when the kind names one
      (`EscalationKind.cause/1`, through `Arbiter.Tasks.Attention.raise_cause/3`).

  System-scoped kinds are written as given: their producers keep their own
  dedupe until child 8 (bd-7gt8rm) gives them a lifecycle.

  Callers keep their own circuit breakers and rescue wrappers; this module
  only decides the row.
  """

  require Logger

  alias Arbiter.Messages.EscalationKind
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Attention

  @type attrs :: %{
          required(:kind) => EscalationKind.t(),
          required(:workspace_id) => String.t(),
          optional(:task_ref) => String.t() | nil,
          optional(:from_ref) => String.t() | nil,
          optional(:subject) => String.t() | nil,
          optional(:body) => String.t(),
          optional(:detail) => String.t() | nil
        }

  @doc """
  Post an escalation. `attrs` takes `:kind` (an `EscalationKind`),
  `:workspace_id`, and optionally `:task_ref`, `:from_ref` (default: the
  `task_ref`, else `"system"`), `:subject`, `:body`, and `:detail` — the
  one-line attention detail recorded with a cause (default: the subject).

  Returns `{:ok, message}` — the new row, or the open one it refreshed — or
  `{:error, reason}`.
  """
  @spec post(attrs()) :: {:ok, struct()} | {:error, term()}
  def post(%{kind: kind} = attrs) do
    if EscalationKind.valid?(kind) do
      row = row(attrs)

      with {:ok, message} <- write(kind, row) do
        record_cause(kind, row, Map.get(attrs, :detail))
        {:ok, message}
      end
    else
      {:error, {:unknown_escalation_kind, kind}}
    end
  end

  defp row(%{kind: kind} = attrs) do
    task_ref = Map.get(attrs, :task_ref)

    %{
      kind: :escalation,
      escalation_kind: kind,
      to_ref: Message.coordinator_ref(),
      from_ref: Map.get(attrs, :from_ref) || task_ref || "system",
      workspace_id: Map.get(attrs, :workspace_id),
      task_ref: task_ref,
      subject: Map.get(attrs, :subject),
      body: Map.get(attrs, :body) || ""
    }
  end

  defp write(kind, %{task_ref: ref, workspace_id: ws} = row) when is_binary(ref) do
    open =
      if EscalationKind.deduped?(kind),
        do: Message.last_escalation(kind, workspace_id: ws, task_ref: ref, open: true)

    case open do
      nil -> Message.send_mail(row)
      message -> Ash.update(message, Map.take(row, [:subject, :body]), action: :refresh)
    end
  end

  defp write(_kind, row), do: Message.send_mail(row)

  defp record_cause(kind, %{task_ref: ref, subject: subject}, detail) when is_binary(ref) do
    case EscalationKind.cause(kind) do
      nil ->
        :ok

      cause ->
        case Attention.raise_cause(ref, cause, detail || subject) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("Escalation: could not record #{cause} on #{ref}: #{inspect(reason)}")
        end
    end
  end

  defp record_cause(_kind, _row, _detail), do: :ok
end
