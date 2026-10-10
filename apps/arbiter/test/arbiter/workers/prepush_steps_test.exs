defmodule Arbiter.Workers.PrepushStepsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Workers.PrepushSteps

  defp result(name, status, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        cmd: "cmd #{name}",
        scope: :all,
        status: status,
        exit_status: if(status == :passed, do: 0, else: 1),
        duration_ms: 12,
        output: "",
        reason: nil
      },
      extra
    )
  end

  test "record/4 writes one row per step, list/1 returns them in recipe order across attempts" do
    run_id = Ash.UUID.generate()

    assert :ok =
             PrepushSteps.record(run_id, "bd-1", 1, [
               result("format", :failed, %{output: "needs formatting"}),
               result("compile", :passed),
               result("credo", :skipped, %{exit_status: nil, output: "skipped: nothing touched"})
             ])

    assert :ok = PrepushSteps.record(run_id, "bd-1", 2, [result("format", :passed)])

    rows = PrepushSteps.list(run_id)

    assert Enum.map(rows, &{&1.attempt, &1.name, &1.status}) == [
             {1, "format", :failed},
             {1, "compile", :passed},
             {1, "credo", :skipped},
             {2, "format", :passed}
           ]

    assert [%{output: "needs formatting", exit_status: 1, duration_ms: 12, cmd: "cmd format"} | _] =
             rows
  end

  test "output is bounded" do
    run_id = Ash.UUID.generate()

    PrepushSteps.record(run_id, "bd-1", 1, [
      result("big", :failed, %{output: String.duplicate("x", 50_000)})
    ])

    assert [%{output: out}] = PrepushSteps.list(run_id)
    assert byte_size(out) <= 8_100
  end

  test "a run with no id records nothing and does not raise" do
    assert :ok = PrepushSteps.record(nil, "bd-1", 1, [result("format", :passed)])
    assert PrepushSteps.list(nil) == []
  end

  test "to_map/1 is the JSON-ready shape" do
    run_id = Ash.UUID.generate()
    PrepushSteps.record(run_id, "bd-1", 1, [result("format", :timeout, %{exit_status: 124})])

    assert [
             %{
               name: "format",
               status: "timeout",
               attempt: 1,
               exit_status: 124,
               duration_ms: 12,
               cmd: "cmd format",
               scope: "all"
             } = map
           ] = run_id |> PrepushSteps.list() |> Enum.map(&PrepushSteps.to_map/1)

    assert Map.has_key?(map, :output)
  end
end
