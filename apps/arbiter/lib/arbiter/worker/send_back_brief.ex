defmodule Arbiter.Worker.SendBackBrief do
  @moduledoc """
  The coordinator's recorded `send_back` resolution, rendered as a resume-prompt block.

  `arb ticket resolve --send-back "<text>"` only records a
  `Arbiter.ReviewGate.Resolution`; the resumed session replays its old context
  and never reads it, so it used to finish in seconds with nothing to do and
  re-push the same head (bd-bk8kae, #976). The manual resume prompt puts the
  reasoning, and the latest reviewer round's findings when that round asked for
  changes, straight into the prompt.

  Only the task's *latest* resolution counts: a later `accept_as_is` / `amend` /
  `reject` supersedes an earlier send-back.
  """

  require Ash.Query

  alias Arbiter.ReviewGate.{Resolution, Resolutions, Round}

  @doc "The latest resolution for `task_id` when it is a `:send_back`, else nil."
  @spec pending(String.t() | nil) :: Resolution.t() | nil
  def pending(task_id) when is_binary(task_id) and task_id != "" do
    case task_id |> Resolutions.list() |> List.last() do
      %Resolution{decision: :send_back} = r -> r
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def pending(_), do: nil

  @doc "Prompt block for `task_id`'s pending send-back, or `\"\"` when there is none."
  @spec section(String.t() | nil) :: String.t()
  def section(task_id) do
    case pending(task_id) do
      nil -> ""
      resolution -> render(task_id, resolution, latest_request_changes(task_id))
    end
  rescue
    _ -> ""
  end

  @doc """
  Flag a send-back whose resume ended without a new commit (bd-bk8kae, #976).

  Called as a ReviewGate starts its first pass on `head_sha`. When the task's
  latest resolution is a `:send_back` recorded against that very head, the
  implementer changed nothing; the coordinator is told instead of the gate
  silently spending a review round on an unchanged SHA. Returns `:flagged` or `:ok`.
  """
  @spec flag_unchanged_head(String.t() | nil, String.t() | nil, String.t() | nil) ::
          :flagged | :ok
  def flag_unchanged_head(task_id, workspace_id, head_sha)
      when is_binary(head_sha) and head_sha != "" do
    case pending(task_id) do
      %Resolution{head_sha: recorded, reasoning: reasoning}
      when is_binary(recorded) and recorded != "" ->
        if same_head?(recorded, head_sha) do
          Arbiter.Messages.CoordinatorNotifier.send_back_unchanged(
            %{task_id: task_id, workspace_id: workspace_id},
            head_sha,
            reasoning
          )

          :flagged
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  def flag_unchanged_head(_task_id, _workspace_id, _head_sha), do: :ok

  # The recorded head may be abbreviated.
  defp same_head?(a, b), do: String.starts_with?(a, b) or String.starts_with?(b, a)

  defp latest_request_changes(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review and verdict == :request_changes)
    |> Ash.Query.sort(inserted_at: :asc, fix_round_attempt: :asc, round: :asc)
    |> Ash.read!()
    |> List.last()
  end

  defp render(task_id, resolution, round) do
    findings =
      case round do
        %Round{findings: text} when is_binary(text) and text != "" ->
          """
          Latest reviewer findings (REQUEST_CHANGES):

          #{String.trim(text)}

          """

        _ ->
          ""
      end

    """

    SENT BACK BY THE COORDINATOR — task #{task_id} was returned to you for changes.
    This is the reason this session was resumed. Make the changes below, commit them,
    and push; a resume that ends with the same head will be flagged to the coordinator.

    Coordinator's instructions:

    #{String.trim(resolution.reasoning)}

    #{findings}
    """
  end
end
