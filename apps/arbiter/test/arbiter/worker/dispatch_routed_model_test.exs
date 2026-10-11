defmodule Arbiter.Worker.DispatchRoutedModelTest do
  @moduledoc """
  bd-3go56q (R9): the model routing picked rides in `opts[:model]` and is
  stripped again when a held dispatch is replayed (`unroute/1`), without ever
  touching a caller's own `:model`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Dispatch

  describe "put_routed_model/2" do
    test "carries a picked model as :model and marks it routing's own" do
      opts = Dispatch.put_routed_model([agent_type: :gemini], "claude-sonnet-4-6")

      assert opts[:model] == "claude-sonnet-4-6"
      assert opts[:routed_model] == "claude-sonnet-4-6"
    end

    test "a default-model selection (nil) changes nothing" do
      assert Dispatch.put_routed_model([agent_type: :claude], nil) == [agent_type: :claude]
    end

    test "a caller's :model wins and is not marked as routed" do
      opts = Dispatch.put_routed_model([model: "opus"], "claude-sonnet-4-6")
      assert opts == [model: "opus"]
    end
  end

  describe "unroute/1" do
    test "drops the model routing set, so the replay routes afresh" do
      opts =
        [agent_type: :gemini, routed_agent_type: :gemini]
        |> Dispatch.put_routed_model("claude-sonnet-4-6")
        |> Keyword.put(:routing_decision, %{"model" => "claude-sonnet-4-6"})
        |> Dispatch.unroute()

      refute Keyword.has_key?(opts, :model)
      refute Keyword.has_key?(opts, :routed_model)
      refute Keyword.has_key?(opts, :agent_type)
    end

    test "keeps a caller's own :model" do
      opts = Dispatch.unroute(model: "opus", routing_decision: %{})
      assert opts == [model: "opus"]
    end
  end
end
