defmodule Arbiter.Agents.FloorsTest do
  @moduledoc """
  bd-c675ny (R8, `docs/design/paced-quota-routing-signals.md` §6.4): the policy
  floor and the per-repo blast-radius floor, and the canary clamp.

  The no-regression half (§9, I1/I2) is pinned here for the policy side: with
  no `routing.floors` config every choice is byte-for-byte what it was.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Floors
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Loop
  alias Arbiter.Loop.Canary
  alias Arbiter.Tasks.{Issue, Workspace}

  @base %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  defp floors(repos), do: put_in(@base, ["routing", "floors"], %{"repos" => repos})

  defp workspace!(config, name \\ "floors-ws") do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: "fl", config: config})
    ws
  end

  describe "repo_floor/2" do
    test "reads routing.floors.repos.<repo>.min_model_tier" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "premium"}}))

      assert Floors.repo_floor(ws, "arbiter") == "premium"
      assert Floors.repo_floor(ws, "other") == nil
      assert Floors.repo_floor(ws, nil) == nil
    end

    test "is nil with no floors config, or a tier off the ladder" do
      assert Floors.repo_floor(workspace!(@base), "arbiter") == nil
      assert Floors.repo_floor(nil, "arbiter") == nil

      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "bogus"}}), "bogus-ws")
      assert Floors.repo_floor(ws, "arbiter") == nil
    end
  end

  describe "gate/2" do
    test "is nil — the whole off path — with nothing configured" do
      assert Floors.gate(workspace!(@base), "arbiter") == nil
      assert Floors.gate(nil, "arbiter") == nil
    end

    test "is armed by a repo floor, or by routing.floors.policy_floor" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "premium"}}))
      assert %{repo_floor: "premium", policy?: false} = Floors.gate(ws, "arbiter")
      assert Floors.gate(ws, "other") == nil

      policy = workspace!(put_in(@base, ["routing", "floors"], %{"policy_floor" => true}), "p")
      assert %{repo_floor: nil, policy?: true} = Floors.gate(policy, "anything")
    end
  end

  describe "the clamp (blast-radius floor on the chosen tier)" do
    test "raises a tier below the repo floor, and records that it did" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "premium"}}))
      task = %Issue{id: "bd-1", difficulty: 1, repo: "arbiter"}

      choice = Routing.choose(task, ws, %{})

      assert choice.config["model_tier"] == "premium"
      assert Floors.clamped?(choice)
      assert choice.floor.from == "economy"
      assert choice.floor.tier == "premium"
    end

    test "never raises a tier already at or above the floor, and records nothing" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "standard"}}))

      for d <- [2, 3, 4] do
        choice = Routing.choose(%Issue{id: "bd-1", difficulty: d, repo: "arbiter"}, ws, %{})
        assert choice.config == ByDifficulty.default_mapping()[d]
        refute Floors.clamped?(choice)
        refute Map.has_key?(choice, :floor)
      end
    end

    test "never lowers: a floor is a minimum, so a higher chosen tier stands" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "economy"}}))
      choice = Routing.choose(%Issue{id: "bd-1", difficulty: 4, repo: "arbiter"}, ws, %{})
      assert choice.config["model_tier"] == "premium"
    end

    test "only the floored repo is clamped" do
      ws = workspace!(floors(%{"arbiter" => %{"min_model_tier" => "premium"}}))
      choice = Routing.choose(%Issue{id: "bd-1", difficulty: 0, repo: "other"}, ws, %{})
      assert choice.config == ByDifficulty.default_mapping()[0]
    end

    test "a pinned model below the floor is dropped with the raised tier" do
      config =
        floors(%{"arbiter" => %{"min_model_tier" => "premium"}})
        |> put_in(["routing", "rules"], %{"D1" => %{"model" => "haiku"}})

      ws = workspace!(config)
      choice = Routing.choose(%Issue{id: "bd-1", difficulty: 1, repo: "arbiter"}, ws, %{})

      assert choice.config["model_tier"] == "premium"
      refute Map.has_key?(choice.config, "model")
    end

    test "applies to every policy, not only by_difficulty" do
      config =
        %{
          "agent" => %{"type" => "claude", "config" => %{}},
          "routing" => %{
            "policy" => "by_priority",
            "rules" => %{"P3" => %{"model_tier" => "economy"}},
            "floors" => %{"repos" => %{"arbiter" => %{"min_model_tier" => "standard"}}}
          }
        }

      ws = workspace!(config)
      choice = Routing.choose(%Issue{id: "bd-1", priority: 3, repo: "arbiter"}, ws, %{})
      assert choice.config["model_tier"] == "standard"
      assert Floors.clamped?(choice)
    end

    test "I1: with no floors config the choice is exactly what it was, for every tier" do
      ws = workspace!(@base)

      for d <- 0..5 do
        assert Routing.choose(%Issue{id: "bd-1", difficulty: d, repo: "arbiter"}, ws, %{}) ==
                 %{type: :claude, config: ByDifficulty.default_mapping()[d]}
      end
    end
  end

  describe "the canary clamp" do
    @lowered %{"model_tier" => "economy", "thinking" => "low"}

    setup do
      ws =
        workspace!(floors(%{"arbiter" => %{"min_model_tier" => "standard"}}), "canary-floor-ws")

      {:ok, row} =
        Loop.record(%{
          kind: :config_set,
          gist: "D2 is over-provisioned: lower D2 to economy/low",
          category: "difficulty misestimate — D2 over-provisioned",
          target: "routing.rules.D2",
          difficulty: 2,
          scope: :fleet,
          target_metric: "first-pass ReviewGate convergence at D2",
          baseline: "90%",
          incident_refs: ["run-a", "run-b", "run-c"],
          task_refs: ["bd-1", "bd-2"],
          payload: %{
            "workspace_id" => ws.id,
            "patch" => %{"routing" => %{"rules" => %{"D2" => @lowered}}}
          },
          origin: "loop.analyze",
          workspace_id: ws.id
        })

      {:ok, ws} =
        Ash.update(ws, %{patch: %{"loop" => %{"autonomous_routing_enabled" => true}}},
          action: :patch_config,
          actor: "operator"
        )

      {:ok, ws} = Canary.start(ws, row, actor: "loop")
      canary = Canary.active(ws)
      canary_id = "bd-" <> to_string(Enum.find(1..200, &(Canary.arm(canary, "bd-#{&1}") == :canary)))

      %{ws: ws, canary_id: canary_id}
    end

    test "a canaried rule below the repo floor is clamped, and the dispatch is recorded clamped",
         %{ws: ws, canary_id: id} do
      choice = Routing.choose(%Issue{id: id, difficulty: 2, repo: "arbiter"}, ws, %{})

      assert choice.config["model_tier"] == "standard"
      # The rest of the canaried rule still applies: only the tier is clamped.
      assert choice.config["thinking"] == "low"
      assert Floors.clamped?(choice)
      assert choice.floor.from == "economy"
    end

    test "the same canaried dispatch in an unfloored repo gets the rule and is not clamped",
         %{ws: ws, canary_id: id} do
      choice = Routing.choose(%Issue{id: id, difficulty: 2, repo: "unfloored"}, ws, %{})

      assert choice.config == @lowered
      refute Floors.clamped?(choice)
    end
  end
end
