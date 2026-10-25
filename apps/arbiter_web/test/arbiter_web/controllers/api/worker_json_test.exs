defmodule ArbiterWeb.Api.WorkerJSONTest do
  use ExUnit.Case, async: true

  alias ArbiterWeb.Api.WorkerJSON

  describe "dispatch/1 (bd-1vdunv)" do
    test "renders a ruling-resumed result, which carries no task/pid/machine" do
      body = WorkerJSON.dispatch(%{result: %{task_id: "bd-x", ruling_resumed: :accept_as_is}})

      assert body.task_id == "bd-x"
      assert body.ruling_resumed == :accept_as_is
      assert body.claude_started == false
      assert body.message =~ "merge path resumed"
    end
  end
end
