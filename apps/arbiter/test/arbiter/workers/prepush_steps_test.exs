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

  describe "full step logs" do
    setup do
      root = Path.join(System.tmp_dir!(), "pc-logs-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:arbiter, :output_log_root)
      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)

        File.rm_rf!(root)
      end)
    end

    test "record/4 saves each executed step's full, redacted output under the run id" do
      run_id = Ash.UUID.generate()
      big = String.duplicate("line\n", 20_000)

      PrepushSteps.record(run_id, "bd-1", 1, [
        result("tests", :failed, %{output: "digest", full_output: big}),
        result("format", :passed, %{full_output: "formatted ok\n"}),
        result("credo", :skipped, %{exit_status: nil, output: "skipped"})
      ])

      assert [tests, format, credo] =
               run_id |> PrepushSteps.list() |> Enum.map(&PrepushSteps.to_map/1)

      assert File.read!(tests.log_path) == big
      assert File.read!(format.log_path) == "formatted ok\n"
      assert credo.log_path == nil
      assert String.starts_with?(tests.log_path, Arbiter.Worker.OutputLog.root())
      assert tests.log_path =~ run_id
    end
  end
end
