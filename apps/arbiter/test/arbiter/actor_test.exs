defmodule Arbiter.ActorTest do
  use ExUnit.Case, async: true

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope

  describe "label/1" do
    test "renders kind alone or kind:id" do
      assert Actor.label(Actor.coordinator()) == "coordinator"
      assert Actor.label(Actor.worker("bd-abc")) == "worker:bd-abc"
      assert Actor.label(Actor.autopilot()) == "autopilot"
      assert Actor.label(Actor.system()) == "system"
      assert Actor.label(Actor.system("merge_queue")) == "system:merge_queue"
      assert Actor.label(Actor.refine("bd-abc")) == "refine:bd-abc"
      assert Actor.label(Actor.operator("ryan")) == "operator:ryan"
      assert Actor.label(Actor.node("gpu-box")) == "node:gpu-box"
    end

    test "an operator with no verified identity says so" do
      assert Actor.label(Actor.operator(nil)) == "operator (unauthenticated)"
    end
  end

  describe "node actors" do
    test "a node is a machine and a valid kind" do
      assert :node in Actor.kinds()
      assert Actor.machine?(Actor.node("gpu-box"))
    end

    test "a node actor round-trips through its label" do
      actor = Actor.node("gpu-box")
      assert actor |> Actor.label() |> Actor.parse() == actor
    end

    test "a node actor without a name labels as plain node" do
      assert Actor.label(Actor.node(nil)) == "node"
      assert Actor.parse("node").kind == :node
    end
  end

  describe "from_scope/1" do
    test "derives the actor from the MCP scope tier and claims" do
      assert Actor.from_scope(%Scope{tier: :coordinator}) == Actor.coordinator()

      assert Actor.from_scope(%Scope{tier: :worker, task_id: "bd-1"}) == Actor.worker("bd-1")

      assert Actor.from_scope(%Scope{tier: :refine, issue_id: "bd-2"}) == Actor.refine("bd-2")
    end

    test "an operator-proof coordinator token is the operator at the CLI" do
      assert Actor.label(Actor.from_scope(%Scope{tier: :coordinator, operator: true})) ==
               "operator:cli"
    end

    test "no scope is an unattributed write" do
      assert Actor.from_scope(nil) == nil
    end
  end

  describe "from/1" do
    test "accepts an actor, a scope, a label string or nil" do
      assert Actor.from(Actor.autopilot()) == Actor.autopilot()
      assert Actor.from(%Scope{tier: :worker, task_id: "bd-1"}) == Actor.worker("bd-1")
      assert Actor.from("worker:bd-9") == Actor.worker("bd-9")
      assert Actor.from(nil) == nil
    end
  end

  describe "parse/1" do
    test "classifies stored labels, legacy ones included" do
      assert Actor.parse("coordinator").kind == :coordinator
      assert Actor.parse("worker:bd-1").kind == :worker
      assert Actor.parse("autopilot").kind == :autopilot
      assert Actor.parse("node:gpu-box") == Actor.node("gpu-box")
      assert Actor.parse("system:merge_queue").kind == :system
      assert Actor.parse("loop:proposal:abc").kind == :system
      assert Actor.parse("operator (unauthenticated)").kind == :operator
      assert Actor.parse("dashboard").kind == :operator
      assert Actor.parse("cli").kind == :operator
    end

    test "round-trips every label" do
      for actor <- [
            Actor.coordinator(),
            Actor.worker("bd-1"),
            Actor.autopilot(),
            Actor.system("reconciler"),
            Actor.operator("ryan"),
            Actor.operator(nil),
            Actor.refine("bd-2")
          ] do
        assert actor |> Actor.label() |> Actor.parse() == actor
      end
    end
  end

  describe "machine?/1" do
    test "operators are human; everything else is a machine" do
      refute Actor.machine?(Actor.operator("x"))
      assert Actor.machine?(Actor.coordinator())
      assert Actor.machine?(Actor.worker("bd-1"))
      assert Actor.machine?(Actor.autopilot())
      assert Actor.machine?(Actor.system())
    end
  end

  describe "ambient actor" do
    test "is per process and restored by with_actor/2" do
      assert Actor.current() == nil

      result =
        Actor.with_actor(Actor.autopilot(), fn ->
          assert Actor.current() == Actor.autopilot()

          Actor.with_actor(Actor.system("x"), fn ->
            assert Actor.current() == Actor.system("x")
          end)

          assert Actor.current() == Actor.autopilot()
          :done
        end)

      assert result == :done
      assert Actor.current() == nil
    end

    test "put/1 sets it for the process and nil clears it" do
      Actor.put(Actor.coordinator())
      assert Actor.current() == Actor.coordinator()
      assert Actor.put(nil) == :ok
      assert Actor.current() == nil
    end

    test "another process does not see it" do
      Actor.put(Actor.coordinator())
      assert Task.async(fn -> Actor.current() end) |> Task.await() == nil
      Actor.put(nil)
    end
  end

  describe "resolve/1" do
    test "an explicit actor wins over the ambient one" do
      Actor.with_actor(Actor.autopilot(), fn ->
        assert Actor.resolve(%Scope{tier: :coordinator}) == Actor.coordinator()
        assert Actor.resolve(nil) == Actor.autopilot()
      end)
    end
  end
end
