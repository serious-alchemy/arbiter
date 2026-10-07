defmodule Arbiter.Tasks.IssueAppendNotesTest do
  @moduledoc """
  P-08 (D-T-19): `Issue :update` takes an `append_notes` argument that appends to
  `notes` server-side, so `arb ticket update --append-notes` is no longer a
  client read-modify-write that loses a concurrent worker's notes write.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "append-ws", prefix: "ap"})
    {:ok, issue} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    {:ok, ws: ws, issue: issue}
  end

  defp append(issue, text), do: Ash.update(issue, %{append_notes: text}, action: :update)

  test "the first append seeds an empty notes field", %{issue: issue} do
    assert {:ok, updated} = append(issue, "one")
    assert updated.notes == "one"
    assert Ash.get!(Issue, issue.id).notes == "one"
  end

  test "later appends are separated by a blank line", %{issue: issue} do
    {:ok, issue} = append(issue, "one")
    assert {:ok, updated} = append(issue, "two")
    assert updated.notes == "one\n\ntwo"
  end

  test "an empty append is a no-op", %{issue: issue} do
    {:ok, issue} = append(issue, "one")
    assert {:ok, updated} = append(issue, "")
    assert updated.notes == "one"
  end

  test "two appends made from the same stale copy both survive", %{issue: issue} do
    # Both callers loaded the ticket before either wrote — the shape of a
    # client read-modify-write racing a worker's `ticket_update_progress`.
    stale_a = Ash.get!(Issue, issue.id)
    stale_b = Ash.get!(Issue, issue.id)

    assert {:ok, _} = append(stale_a, "from-a")
    assert {:ok, _} = append(stale_b, "from-b")

    notes = Ash.get!(Issue, issue.id).notes
    assert notes =~ "from-a"
    assert notes =~ "from-b"
  end

  test "concurrent appends all survive", %{issue: issue} do
    texts = for n <- 1..8, do: "note-#{n}"

    texts
    |> Task.async_stream(
      fn text -> append(Ash.get!(Issue, issue.id), text) end,
      max_concurrency: 8,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)

    notes = Ash.get!(Issue, issue.id).notes
    for text <- texts, do: assert(notes =~ text)
  end

  test "append_notes together with notes is refused", %{issue: issue} do
    assert {:error, error} =
             Ash.update(issue, %{notes: "set", append_notes: "add"}, action: :update)

    assert Exception.message(error) =~ "append_notes"
    assert Ash.get!(Issue, issue.id).notes == nil
  end

  test "notes \"\" clears the field", %{issue: issue} do
    {:ok, issue} = append(issue, "one")
    assert {:ok, updated} = Ash.update(issue, %{notes: ""}, action: :update)
    assert updated.notes == nil
  end
end
