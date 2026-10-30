defmodule Arbiter.Utf8TextTablesTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Utf8TextBackfill, Workspace}
  alias Arbiter.Workers.{PrepushStep, PrepushSteps}

  @bad <<"cut at ", 0xB1, " mid">>

  defp step(output) do
    %{
      name: "format",
      cmd: "mix format",
      scope: :all,
      status: :failed,
      exit_status: 1,
      duration_ms: 5,
      output: output,
      reason: nil
    }
  end

  defp message!(attrs \\ %{}) do
    ws = Ash.create!(Workspace, %{name: "u8m-#{System.unique_integer([:positive])}"})

    Ash.create!(
      Message,
      Map.merge(
        %{
          kind: :mailbox,
          from_ref: "coordinator",
          to_ref: "bd-x",
          body: "ok",
          workspace_id: ws.id
        },
        attrs
      )
    )
  end

  test "writing a message with invalid UTF-8 stores valid UTF-8" do
    m = message!(%{subject: @bad, body: @bad})
    stored = Ash.get!(Message, m.id)
    assert String.valid?(stored.body) and stored.body =~ "�"
    assert String.valid?(stored.subject)

    refreshed = Ash.update!(m, %{body: @bad}, action: :refresh)
    assert String.valid?(Ash.get!(Message, refreshed.id).body)
  end

  test "recording a prepush step with invalid UTF-8 output stores valid UTF-8" do
    run_id = Ash.UUID.generate()
    :ok = PrepushSteps.record(run_id, "bd-1", 1, [step(@bad)])
    assert [row] = PrepushSteps.list(run_id)
    assert String.valid?(row.output) and row.output =~ "�"
  end

  test "PrepushSteps.to_map scrubs a legacy invalid row" do
    run_id = Ash.UUID.generate()
    :ok = PrepushSteps.record(run_id, "bd-1", 1, [step("fine")])
    [row] = PrepushSteps.list(run_id)
    Repo.query!("UPDATE worker_prepush_steps SET output = ?1 WHERE id = ?2", [@bad, row.id])

    [raw] = PrepushSteps.list(run_id)
    assert {:ok, _} = raw |> PrepushSteps.to_map() |> Jason.encode()
  end

  test "backfill reports per table, repairs only invalid rows, and is idempotent" do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "u8-#{System.unique_integer([:positive])}", prefix: "u8"})

    issue = Ash.create!(Issue, %{title: "t", workspace_id: ws.id, issue_type: :feature})
    m = message!()
    good = message!(%{body: "héllo"})
    run_id = Ash.UUID.generate()
    :ok = PrepushSteps.record(run_id, "bd-1", 1, [step("fine")])
    [ps] = PrepushSteps.list(run_id)

    Repo.query!("UPDATE issues SET notes = ?1 WHERE id = ?2", [@bad, issue.id])
    Repo.query!("UPDATE messages SET body = ?1 WHERE id = ?2", [@bad, m.id])
    Repo.query!("UPDATE worker_prepush_steps SET output = ?1 WHERE id = ?2", [@bad, ps.id])

    dry = Utf8TextBackfill.backfill()
    for t <- ~w(issues messages worker_prepush_steps), do: assert(dry.tables[t].would_repair == 1)
    assert dry.would_repair == 3

    refute String.valid?(
             Repo.query!("SELECT body FROM messages WHERE id = ?1", [m.id]).rows
             |> hd()
             |> hd()
           )

    applied = Utf8TextBackfill.backfill(apply?: true)
    assert applied.repaired == 3

    assert String.valid?(Ash.get!(Message, m.id).body)
    assert Ash.get!(Message, good.id).body == "héllo"
    assert String.valid?(Ash.get!(PrepushStep, ps.id).output)

    again = Utf8TextBackfill.backfill(apply?: true)
    assert again.repaired == 0 and again.would_repair == 0
  end
end
