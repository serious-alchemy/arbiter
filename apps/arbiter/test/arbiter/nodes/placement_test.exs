defmodule Arbiter.Nodes.PlacementTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Placement

  @eligible %{
    task_id: "bd-place1",
    workspace_id: "ws-1",
    kind: :implementer,
    provider: :claude,
    layout: :private_clone,
    no_pr?: false,
    mode: :prefer_remote
  }

  defp row(name, attrs \\ []) do
    Map.merge(
      %{
        id: "node-" <> name,
        name: name,
        state: :online,
        health: :ready,
        labels: [],
        workspace_ids: [],
        live: 0,
        max: 2
      },
      Map.new(attrs)
    )
  end

  defp place(request, rows, opts \\ []) do
    Placement.place(
      Map.merge(@eligible, Map.new(request)),
      Keyword.merge([nodes: rows, remote_available?: true], opts)
    )
  end

  describe "mode/1" do
    test "defaults to local_only and reads worker.placement from a workspace config" do
      assert Placement.mode(nil) == :local_only
      assert Placement.mode(%{config: %{}}) == :local_only

      assert Placement.mode(%{config: %{"worker" => %{"placement" => "prefer_remote"}}}) ==
               :prefer_remote

      assert Placement.mode(%{config: %{"worker" => %{"placement" => "remote_only"}}}) ==
               :remote_only
    end

    test "an unknown value falls back to local_only rather than going remote" do
      assert Placement.mode(%{config: %{"worker" => %{"placement" => "everywhere"}}}) ==
               :local_only

      assert Placement.mode(%{config: %{"worker" => %{"placement" => 3}}}) == :local_only
    end
  end

  describe "eligible/1 (eligibility first: only a podman Claude run on a private clone)" do
    test "the podman-backed Claude implementer with a private clone is eligible" do
      assert Placement.eligible(@eligible) == :ok
    end

    # bd-7ays3v: these run in the container on a private clone too; bd-cgdhlu adds
    # the `review: true` dispatch (kind `:review`).
    test "so are a ReviewGate reviewer, a review: true dispatch and the merge queue's fix and conflict passes" do
      for kind <- [:reviewer, :review, :fix_pass, :conflict_pass] do
        assert Placement.eligible(%{@eligible | kind: kind}) == :ok

        assert {:local_only, :not_podman} =
                 Placement.eligible(%{@eligible | kind: kind, layout: :worktree})

        assert {:local_only, :non_claude_provider} =
                 Placement.eligible(%{@eligible | kind: kind, provider: :codex})
      end
    end

    test "every other spawn kind stays local" do
      for kind <- [:redispatch, :resume, :review_fix_round] do
        assert {:local_only, :follow_up} = Placement.eligible(%{@eligible | kind: kind})
      end
    end

    test "a non-Claude provider stays local" do
      for provider <- [:codex, :agy, :gemini, :grok] do
        assert {:local_only, :non_claude_provider} =
                 Placement.eligible(%{@eligible | provider: provider})
      end
    end

    test "a bwrap-jailed or unsandboxed layout stays local" do
      for layout <- [:worktree, :shared, nil] do
        assert {:local_only, :not_podman} = Placement.eligible(%{@eligible | layout: layout})
      end
    end

    test "a dispatch with no private clone (task/research) stays local" do
      assert {:local_only, :no_private_clone} = Placement.eligible(%{@eligible | no_pr?: true})
    end

    test "a local_only workspace keeps even an eligible run local" do
      assert {:local_only, :placement_local_only} =
               Placement.eligible(%{@eligible | mode: :local_only})
    end

    test "every reason has a phrase the hold message can use" do
      for reason <- [
            :follow_up,
            :non_claude_provider,
            :not_podman,
            :no_private_clone,
            :placement_local_only
          ] do
        assert is_binary(Placement.reason_phrase(reason, %{kind: :reviewer, provider: :codex}))
      end
    end
  end

  describe "constrained nodes (A3) and degraded: netpol_unenforced (A7)" do
    test "a constrained node ranks last even when it is the emptiest" do
      rows = [row("idle-but-constrained", constrained?: true), row("busy", live: 1, max: 2)]
      assert {:ok, {:node, %{name: "busy"}}} = place(%{mode: :remote_only}, rows)
    end

    test "prefer_remote skips a constrained node and runs locally when nothing else can take it" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a", constrained?: true)])
    end

    test "remote_only has no local to fall back on: a constrained node is the last resort" do
      assert {:ok, {:node, %{name: "a"}}} =
               place(%{mode: :remote_only}, [row("a", constrained?: true)])
    end

    test "a node that is not constrained is unaffected, with or without the key" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a", constrained?: false)])
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a")])
    end

    test "a netpol_unenforced node is excluded" do
      rows = [row("a", degraded: ["netpol_unenforced"])]
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, rows)
      assert {:ok, {:local, :no_node}} = place(%{}, rows)
    end

    test "the per-node allow_unenforced_network override admits it again" do
      rows = [row("a", degraded: ["netpol_unenforced"], allow_unenforced_network: true)]
      assert {:ok, {:node, %{name: "a"}}} = place(%{mode: :remote_only}, rows)
    end

    test "the override covers only netpol_unenforced, not other degradations" do
      rows = [row("a", degraded: ["something_else"], allow_unenforced_network: true)]
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows)
    end

    test "a healthy node is picked over an overridden unenforced one only by ranking, not exclusion" do
      rows = [
        row("a", degraded: ["netpol_unenforced"], allow_unenforced_network: true),
        row("b", live: 1, max: 2)
      ]

      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows)
    end
  end

  describe "place/2" do
    test "an ineligible run is placed locally without consulting the pool" do
      rows = fn -> flunk("the node pool must not be read for an ineligible run") end

      assert {:ok, {:local, {:local_only, :follow_up}}} =
               Placement.place(%{@eligible | kind: :redispatch},
                 nodes: rows,
                 remote_available?: true
               )
    end

    test "local_only (the default) is always local, even with a node free" do
      assert {:ok, {:local, {:local_only, :placement_local_only}}} =
               place(%{mode: :local_only}, [row("a")])
    end

    test "the seam can switch remote execution off: placement is then always local" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a")], remote_available?: false)
    end

    # bd-afcoop (RW13): `Executor.Node` exists since RW9, so nothing but `worker.placement`
    # (default local_only) keeps a run off a node. With the old default of `false`, a real
    # dispatch could never reach a node whatever the operator configured.
    test "with no seam, remote execution is available: a free node is picked" do
      assert {:ok, {:node, %{name: "a"}}} =
               Placement.place(Map.merge(@eligible, %{mode: :prefer_remote}), nodes: [row("a")])

      assert {:ok, {:local, {:local_only, :placement_local_only}}} =
               Placement.place(Map.merge(@eligible, %{mode: :local_only}), nodes: [row("a")])
    end

    test "prefer_remote picks a node with headroom" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a")])
    end

    test "prefer_remote falls back to local when no node has a free slot" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a", live: 2, max: 2)])
    end

    test "remote_only with no capacity is {:no_node_capacity, info}" do
      assert {:error, {:no_node_capacity, info}} =
               place(%{mode: :remote_only}, [row("a", live: 2, max: 2)])

      assert info.mode == :remote_only
      assert info.task_id == "bd-place1"
      assert info.node == nil
      assert Placement.refusal_message(info) =~ "held"
    end

    test "remote_only with no nodes at all, or before RW9, is {:no_node_capacity, _}" do
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [])

      assert {:error, {:no_node_capacity, _}} =
               place(%{mode: :remote_only}, [row("a")], remote_available?: false)
    end

    # bd-cgdhlu: a reviewer is placed like any eligible run.
    test "a ReviewGate reviewer and a review dispatch: prefer_remote takes a node with headroom, else local" do
      for kind <- [:reviewer, :review] do
        assert {:ok, {:node, %{name: "a"}}} = place(%{kind: kind}, [row("a")])
        Placement.release("bd-place1")

        assert {:ok, {:local, :no_node}} =
                 place(%{kind: kind}, [row("a", live: 2, max: 2)])
      end
    end

    test "a reviewer under remote_only is held when no node has room, and placed when one has" do
      for kind <- [:reviewer, :review] do
        assert {:error, {:no_node_capacity, info}} =
                 place(%{kind: kind, mode: :remote_only}, [row("a", live: 2, max: 2)])

        assert info.mode == :remote_only

        assert {:ok, {:node, %{name: "b"}}} =
                 place(%{kind: kind, mode: :remote_only}, [row("a", live: 2, max: 2), row("b")])

        Placement.release("bd-place1")
      end
    end

    test "a reviewer in a local_only workspace, or one with no podman, never goes remote" do
      for kind <- [:reviewer, :review] do
        assert {:ok, {:local, {:local_only, :placement_local_only}}} =
                 place(%{kind: kind, mode: :local_only}, [row("a")])

        assert {:ok, {:local, {:local_only, :not_podman}}} =
                 place(%{kind: kind, layout: :linked_worktree}, [row("a")])
      end
    end

    test "remote_only still lets an ineligible run go local" do
      assert {:ok, {:local, {:local_only, :follow_up}}} =
               place(%{mode: :remote_only, kind: :redispatch}, [])
    end

    test "offline, suspect, draining, revoked and unhealthy nodes are not candidates" do
      rows =
        for {name, attrs} <- [
              {"off", state: :offline},
              {"sus", state: :suspect},
              {"drn", state: :draining},
              {"rev", state: :revoked},
              {"old", health: :outdated},
              {"inc", health: :incompatible},
              {"ahd", health: :ahead}
            ],
            do: row(name, attrs)

      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, rows)
    end

    test "a node with no known cap is not a candidate" do
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [row("a", max: nil)])
    end

    test "a workspace pin is an allowlist: unpinned nodes take any workspace" do
      pinned = row("pinned", workspace_ids: ["other-ws"])
      open = row("open")
      mine = row("mine", workspace_ids: ["ws-1"])

      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [pinned])
      assert {:ok, {:node, %{name: "open"}}} = place(%{}, [pinned, open])
      assert {:ok, {:node, %{name: "mine"}}} = place(%{}, [pinned, mine])
    end

    test "required labels must all be on the node" do
      rows = [row("a", labels: ["zone=a"]), row("b", labels: ["zone=a", "gpu=yes"])]
      assert {:ok, {:node, %{name: "b"}}} = place(%{labels: ["gpu=yes"]}, rows)
    end

    test "ranks by lowest live/max, then name" do
      assert {:ok, {:node, %{name: "big"}}} =
               place(%{}, [row("busy", live: 1, max: 2), row("big", live: 1, max: 4)])

      assert {:ok, {:node, %{name: "idle"}}} =
               place(%{}, [row("busy", live: 1, max: 2), row("idle", live: 0, max: 2)])

      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("b"), row("a")])
    end

    test "a placement reserves its slot until released, so a burst cannot overbook" do
      rows = [row("solo", max: 1)]
      parent = self()

      holder =
        spawn_link(fn ->
          send(parent, {:placed, place(%{task_id: "bd-first"}, rows)})

          receive do
            :release ->
              Placement.release("bd-first")
              send(parent, :released)
          end
        end)

      assert_receive {:placed, {:ok, {:node, _}}}

      assert {:error, {:no_node_capacity, _}} =
               place(%{task_id: "bd-second", mode: :remote_only}, rows)

      send(holder, :release)
      assert_receive :released
      assert {:ok, {:node, _}} = place(%{task_id: "bd-second"}, rows)
    end
  end
end
