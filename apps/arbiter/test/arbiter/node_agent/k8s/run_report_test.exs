defmodule Arbiter.NodeAgent.K8s.RunReportTest do
  @moduledoc """
  The controller's wire payloads in the shapes the primary reads (K14): `Session` takes a
  `run.refused` only with its `run`, and keys the runs of `hello.inventory` and `hb.runs`
  by `id` (`Arbiter.Nodes.Session.hello_runs/1`), as the machine agent's `Run` reports them.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.RunReport

  test "run.refused names its run, its reason as a word and the detail" do
    assert RunReport.refused("run-1", :unschedulable, "0/3 nodes are available") == %{
             "run" => "run-1",
             "reason" => "unschedulable",
             "detail" => "0/3 nodes are available"
           }
  end

  test "an inventory entry carries the run as `id` (the primary's key) and as `run`" do
    entry = %{run: "run-1", pod: "arb-run-1", phase: :live, state: :pending, detail: %{}}

    assert %{"id" => "run-1", "run" => "run-1", "pod" => "arb-run-1", "state" => "pending"} =
             RunReport.inventory(entry)
  end

  test "a pending run's reason and message ride along" do
    entry = %{
      run: "run-1",
      pod: "arb-run-1",
      phase: :live,
      state: :pending,
      detail: %{reason: :unschedulable, message: "0/3 nodes"}
    }

    assert %{"reason" => "unschedulable", "message" => "0/3 nodes"} = RunReport.inventory(entry)
  end
end
