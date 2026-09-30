defmodule Arbiter.Boot.OptimizeTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Boot.Optimize

  describe "child_spec/1" do
    test "is a one-shot temporary worker with this module's id" do
      spec = Optimize.child_spec([])

      assert spec.id == Arbiter.Boot.Optimize
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert {Arbiter.Boot.Optimize, :start_link, [[]]} = spec.start
    end
  end

  describe "start_link/1 gating" do
    test "returns :ignore when not primary or disabled" do
      assert Optimize.start_link(primary?: false) == :ignore
      assert Optimize.start_link(primary?: true, enabled: false) == :ignore
    end

    test "runs PRAGMA optimize on primary instance and logs" do
      Logger.put_module_level(Optimize, :info)
      on_exit(fn -> Logger.delete_module_level(Optimize) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Optimize.start_link(primary?: true, enabled: true) == :ignore
        end)

      assert log =~ "PRAGMA optimize ran successfully"
    end
  end
end
