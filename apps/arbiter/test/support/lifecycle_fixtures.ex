defmodule Arbiter.LifecycleFixtures do
  @moduledoc """
  Walks a test ticket into a lifecycle state through the real transition
  actions (`Arbiter.Tasks.Lifecycle`).

  bd-36ytcl removed the legacy `status` / `refined` columns, and with them
  the `Ash.update(issue, %{status: :in_progress})` shortcut tests used to put
  a ticket to work. `put_state!/3` is the replacement: it takes whatever
  route the table allows from the ticket's current state, so the row reached
  is one production could reach, with the same side effects.

      ticket |> put_state!(:active)
      ticket |> put_state!(:merging, pr_ref: "https://…/pull/7")
  """

  alias Arbiter.Tasks.Issue

  @doc """
  Moves `issue` into `state` and returns the updated ticket.

  Options:

    * `:pr_ref` — the ref the `open_pr` step records (default
      `"https://example.test/pull/1"`), for `:merging`.
  """
  @spec put_state!(Issue.t(), Arbiter.Tasks.Lifecycle.state(), keyword()) :: Issue.t()
  def put_state!(issue, state, opts \\ [])

  def put_state!(%Issue{state: state} = issue, state, _opts), do: issue

  def put_state!(%Issue{} = issue, :backlog, _opts) do
    issue |> leave_verifying_or_closed() |> step!(:demote)
  end

  def put_state!(%Issue{} = issue, :queued, _opts) do
    case issue.state do
      :backlog -> step!(issue, :promote, %{acceptance_waived: "test fixture"})
      state when state in [:active, :merging] -> step!(issue, :requeue)
      state when state in [:verifying, :closed] -> step!(issue, :reopen)
    end
  end

  def put_state!(%Issue{} = issue, :active, _opts) do
    case issue.state do
      state when state in [:backlog, :queued] -> step!(issue, :start)
      :merging -> step!(issue, :return_to_work)
      _verifying_or_closed -> issue |> step!(:reopen) |> step!(:start)
    end
  end

  def put_state!(%Issue{} = issue, :merging, opts) do
    pr_ref = Keyword.get(opts, :pr_ref) || issue.pr_ref || "https://example.test/pull/1"

    issue
    |> put_state!(:active)
    |> step!(:open_pr, %{pr_ref: pr_ref})
  end

  def put_state!(%Issue{} = issue, :verifying, _opts) do
    issue |> put_state!(:active) |> step!(:await_verification)
  end

  def put_state!(%Issue{} = issue, :closed, _opts), do: step!(issue, :close)

  defp leave_verifying_or_closed(%Issue{state: state} = issue)
       when state in [:verifying, :closed],
       do: step!(issue, :reopen)

  defp leave_verifying_or_closed(issue), do: issue

  defp step!(issue, action, args \\ %{}), do: Ash.update!(issue, args, action: action)
end
