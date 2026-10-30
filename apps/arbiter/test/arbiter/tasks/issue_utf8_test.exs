defmodule Arbiter.Tasks.IssueUtf8Test do
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, IssueSerializer, Utf8TextBackfill, Workspace}
  alias Arbiter.Worker.PrepushCheck

  @bad <<"not found within ", 0xB1, "60 lines">>

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "utf8-#{System.unique_integer([:positive])}", prefix: "ut"})

    {:ok, issue} = Ash.create(Issue, %{title: "utf8", workspace_id: ws.id, issue_type: :feature})
    %{issue: issue}
  end

  defp plant_invalid!(issue) do
    Repo.query!("UPDATE issues SET notes = ?1 WHERE id = ?2", [@bad, issue.id])
  end

  test "PrepushCheck.tail never splits a codepoint" do
    text = String.duplicate("not found within ±60 lines ─│\n", 200)

    for max <- 100..140 do
      assert String.valid?(PrepushCheck.tail(text, max))
    end
  end

  test "writing invalid UTF-8 stores valid UTF-8", %{issue: issue} do
    {:ok, updated} = Ash.update(issue, %{notes: @bad, description: @bad})
    assert String.valid?(updated.notes)
    assert updated.notes =~ "�"
    assert String.valid?(Ash.get!(Issue, issue.id).description)

    {:ok, appended} = Ash.update(updated, %{append_notes: @bad})
    assert String.valid?(Ash.get!(Issue, appended.id).notes)

    {:ok, created} =
      Ash.create(Issue, %{
        title: "c",
        description: @bad,
        workspace_id: issue.workspace_id,
        issue_type: :feature
      })

    assert String.valid?(created.description)
  end

  test "serializer renders legacy invalid UTF-8 as encodable text", %{issue: issue} do
    plant_invalid!(issue)
    data = issue.id |> then(&Ash.get!(Issue, &1)) |> IssueSerializer.data()
    assert String.valid?(data.notes)
    assert {:ok, _} = Jason.encode(data)
  end

  test "backfill repairs legacy rows", %{issue: issue} do
    plant_invalid!(issue)
    assert %{would_repair: n} = Utf8TextBackfill.backfill()
    assert n >= 1
    assert %{repaired: m} = Utf8TextBackfill.backfill(apply?: true)
    assert m >= 1
    assert Ash.get!(Issue, issue.id).notes == "not found within �60 lines"
  end
end
