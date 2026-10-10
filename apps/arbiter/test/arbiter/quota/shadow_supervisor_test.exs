defmodule Arbiter.Quota.ShadowSupervisorTest do
  @moduledoc """
  bd-1p8cxk: v0.2.42's `Budget.Server` crash loop exhausted the top-level
  supervisor's restart intensity and shut the application down. A shadow-only
  component must not be able to do that.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Quota.Budget.Server
  alias Arbiter.Quota.ShadowSupervisor

  test "the supervisor is temporary: giving up never restarts or escalates into the app" do
    assert %{restart: :temporary, type: :supervisor} = ShadowSupervisor.child_spec([])
  end

  test "the application starts it in place of the bare server" do
    child_ids =
      Arbiter.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    assert ShadowSupervisor in child_ids
    refute Server in child_ids
  end

  test "a server killed far past the default restart intensity does not take anything down" do
    name = :"shadow_server_#{System.unique_integer([:positive])}"
    table = :"shadow_table_#{System.unique_integer([:positive])}"

    server_opts = [name: name, table: table, enabled: false, calibration: :never]
    sup = start_supervised!({ShadowSupervisor, server_opts: server_opts})
    sup_ref = Process.monitor(sup)

    for _ <- 1..25 do
      pid = Process.whereis(name)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      wait_for_restart(name, pid)
    end

    refute_received {:DOWN, ^sup_ref, :process, ^sup, _}
    assert is_pid(Process.whereis(name))
  end

  defp wait_for_restart(name, old_pid) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _ ->
        :erlang.yield()
        wait_for_restart(name, old_pid)
    end
  end
end
