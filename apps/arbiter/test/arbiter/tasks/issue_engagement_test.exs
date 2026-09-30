defmodule Arbiter.Tasks.IssueEngagementTest do
  @moduledoc """
  The review-engagement predicate (`review_only == true and not is_nil(source_pr)`)
  lives in exactly one place — `Issue.engagement?` plus the `exclude_engagements/1`
  and `only_engagements/1` query helpers. These tests pin the conjunction: neither
  half alone makes an engagement.
  """
  use Arbiter.DataCase, async: true

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}

  defp ws! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "eng-#{System.unique_integer([:positive])}",
        prefix: "en#{System.unique_integer([:positive])}"
      })

    ws
  end

  defp issue!(ws, title, attrs) do
    Ash.create!(Issue, Map.merge(%{title: title, tracker_type: :none, workspace_id: ws.id}, attrs))
  end

  setup do
    ws = ws!()

    %{
      ws: ws,
      engagement: issue!(ws, "engagement", %{review_only: true, source_pr: "7"}),
      worker_review: issue!(ws, "worker review", %{review_only: true}),
      follow_up: issue!(ws, "pr follow-up", %{source_pr: "8"}),
      plain: issue!(ws, "plain", %{})
    }
  end

  defp ids(query), do: query |> Ash.read!() |> MapSet.new(& &1.id)

  test "exclude_engagements/1 drops only the conjunction", ctx do
    got = Issue |> Issue.exclude_engagements() |> Ash.Query.filter(workspace_id == ^ctx.ws.id) |> ids()

    assert got == MapSet.new([ctx.worker_review.id, ctx.follow_up.id, ctx.plain.id])
  end

  test "only_engagements/1 keeps only the conjunction", ctx do
    got = Issue |> Issue.only_engagements() |> Ash.Query.filter(workspace_id == ^ctx.ws.id) |> ids()

    assert got == MapSet.new([ctx.engagement.id])
  end

  test "a NULL review_only row is not an engagement (and is not dropped by exclude)", ctx do
    # `review_only` is nullable; a NULL must behave as false, not as SQL unknown.
    Arbiter.Repo.query!("UPDATE issues SET review_only = NULL WHERE id = ?", [ctx.follow_up.id])

    got = Issue |> Issue.exclude_engagements() |> Ash.Query.filter(workspace_id == ^ctx.ws.id) |> ids()
    assert ctx.follow_up.id in got
  end

  test "engagement? loads as a boolean per row", ctx do
    loaded =
      Issue
      |> Ash.Query.filter(workspace_id == ^ctx.ws.id)
      |> Ash.Query.load(:engagement?)
      |> Ash.read!()
      |> Map.new(&{&1.id, &1.engagement?})

    assert loaded[ctx.engagement.id] == true
    assert loaded[ctx.worker_review.id] == false
    assert loaded[ctx.follow_up.id] == false
    assert loaded[ctx.plain.id] == false
  end
end
