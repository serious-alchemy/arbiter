defmodule Arbiter.Boot.ResumeGateTest do
  use ExUnit.Case, async: false

  alias Arbiter.Boot.ResumeGate

  setup do
    on_exit(fn -> ResumeGate.open() end)
  end

  test "is open until closed, and sweep/1 opens it again" do
    assert ResumeGate.open?()
    ResumeGate.close()
    refute ResumeGate.open?()

    assert :done = ResumeGate.sweep(fn -> :done end)
    assert ResumeGate.open?()
  end

  test "sweep/1 opens the gate when the sweep raises" do
    ResumeGate.close()
    assert_raise RuntimeError, fn -> ResumeGate.sweep(fn -> raise "boom" end) end
    assert ResumeGate.open?()
  end

  test "a gate that was never opened expires, so a killed boot cannot wedge the scheduler" do
    ResumeGate.close(max_closed_ms: 0)
    assert ResumeGate.open?()
  end

  test "opening tells a running autopilot to plan" do
    {:ok, pid} =
      Arbiter.Board.Autopilot.start_link(name: nil, paused: true, interval_ms: :never, topics: [])

    ResumeGate.close()
    assert :ok = ResumeGate.sweep(fn -> :ok end)
    assert Process.alive?(pid)
    assert :ok = Arbiter.Board.Autopilot.resumes_settled(pid)
  end

  test "the app's boot children close the gate ahead of Autopilot, only when boot tasks run" do
    ids = fn auto_start? ->
      [auto_start?: auto_start?]
      |> Arbiter.Application.children()
      |> Enum.map(fn
        %{id: id} -> id
        {mod, _} -> mod
        mod -> mod
      end)
    end

    on = ids.(true)

    assert Enum.find_index(on, &(&1 == Arbiter.Boot.ResumeGate)) <
             Enum.find_index(on, &(&1 == Arbiter.Board.Autopilot))

    refute Arbiter.Boot.ResumeGate in ids.(false)
  end
end
