defmodule Arbiter.Machine.HoldTest do
  use ExUnit.Case, async: true

  alias Arbiter.Machine.Hold

  @hot_local %{cap: 4, offered: 1, derate: :hard, derate_reason: "thermal 96 °C"}
  @cool_local %{cap: 4, offered: 4, derate: :none, derate_reason: nil}

  defp node(name, derate, reason \\ nil),
    do: %{name: name, id: name, state: :online, derate: derate, derate_reason: reason}

  test "local_only only looks at the primary" do
    nodes = [node("box", :hard, "thermal 99 °C")]

    assert [%{name: "local", level: :hard, reason: "thermal 96 °C"}] =
             Hold.derated(:local_only, local: @hot_local, nodes: nodes, remote_available?: true)

    assert Hold.derated(:local_only, local: @cool_local, nodes: nodes, remote_available?: true) ==
             []
  end

  test "remote_only only looks at the nodes, and only online ones" do
    nodes = [
      node("box", :soft, "thermal 91 °C"),
      %{node("gone", :hard, "x") | state: :offline},
      node("fine", :none)
    ]

    assert [%{name: "box", level: :soft, reason: "thermal 91 °C"}] =
             Hold.derated(:remote_only, local: @hot_local, nodes: nodes, remote_available?: true)
  end

  test "prefer_remote looks at both; nodes are ignored while remote execution is off" do
    nodes = [node("box", :hard, "thermal 97 °C")]

    assert ["local", "box"] ==
             :prefer_remote
             |> Hold.derated(local: @hot_local, nodes: nodes, remote_available?: true)
             |> Enum.map(& &1.name)

    assert ["local"] ==
             :prefer_remote
             |> Hold.derated(local: @hot_local, nodes: nodes, remote_available?: false)
             |> Enum.map(& &1.name)
  end

  test "note/2 rewrites a hold as the machine and what it sensed, and leaves no hold alone" do
    derated = [%{name: "ryan-oryx-pro", level: :hard, reason: "thermal 96 °C"}]

    assert Hold.note("held — no free slot …", derated) =~ "held — ryan-oryx-pro thermal 96 °C"
    assert Hold.note("held — no free slot …", []) == "held — no free slot …"
    assert Hold.note(nil, derated) == nil
  end

  test "several derated machines are all named" do
    derated = [
      %{name: "local", level: :soft, reason: "memory pressure (PSI some avg10 31.0%)"},
      %{name: "box", level: :hard, reason: "thermal 96 °C"}
    ]

    note = Hold.note("held", derated)
    assert note =~ "local memory pressure"
    assert note =~ "box thermal 96 °C"
  end
end
