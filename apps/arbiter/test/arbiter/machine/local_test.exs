defmodule Arbiter.Machine.LocalTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Machine.Local
  alias Arbiter.Settings

  setup do
    previous = Application.fetch_env(:arbiter, :machine_monitor)

    on_exit(fn ->
      Settings.set_machine_derate(nil)

      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :machine_monitor, v)
        :error -> Application.delete_env(:arbiter, :machine_monitor)
      end
    end)
  end

  test "the primary's thresholds are the machine.derate setting over the defaults" do
    assert Local.config().thermal_soft_c == 90.0
    {:ok, _} = Settings.set_machine_derate(%{"thermal_soft_c" => 80, "enabled" => true})
    assert Local.config().thermal_soft_c == 80.0
    assert Local.config().thermal_hard_c == 95.0
  end

  test "on by default; :machine_monitor false keeps it from starting" do
    Application.delete_env(:arbiter, :machine_monitor)
    assert [{Arbiter.Machine.Monitor, opts}] = Local.child_specs()
    assert opts[:name] == Arbiter.Machine.Monitor

    Application.put_env(:arbiter, :machine_monitor, false)
    assert Local.child_specs() == []
  end

  test "the real monitor child samples this host and LocalCapacity reads it" do
    Application.put_env(:arbiter, :machine_monitor, true)
    # The app's own `Local` supervisor runs empty in the suite (monitor off); start its child.
    start_supervised!(hd(Local.child_specs()))
    snapshot = Arbiter.Machine.Monitor.sample()
    assert snapshot.level in [:none, :soft, :hard]
    assert is_integer(snapshot.offered)
    assert Arbiter.Nodes.LocalCapacity.cap().derate == snapshot.level
  end
end
