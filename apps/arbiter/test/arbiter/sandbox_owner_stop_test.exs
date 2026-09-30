defmodule Arbiter.SandboxOwnerStopTest do
  @moduledoc """
  Regression test for bd-jw7cb0: `Arbiter.DataCase.stop_sandbox_owner/1` must
  leave a shared pool unshared by the time it returns.

  A plain `ExUnit.Case`, because it needs to own the shared mode itself. A
  `DataCase` test would already hold it.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox

  test "a query right after stop_sandbox_owner/1 is refused, not sent to the dead owner's proxy" do
    owner = Sandbox.start_owner!(Arbiter.Repo, shared: true)
    proxy = proxy_of(owner)

    # A suspended proxy can't process its owner's death, which holds open the
    # window CI hit by chance. Without the synchronous checkin, the manager
    # would still redirect the query below to this proxy, and on resume the
    # proxy would handle the owner's `:DOWN` first and exit the query with
    # `{:shutdown, "owner … exited"}`.
    :sys.suspend(proxy)
    ref = Process.monitor(proxy)
    Arbiter.DataCase.stop_sandbox_owner(owner)

    query =
      Task.async(fn ->
        try do
          Arbiter.Repo.query!("SELECT 1")
        rescue
          e -> {:raised, e}
        catch
          :exit, reason -> {:exited, reason}
        end
      end)

    :sys.resume(proxy)
    assert_receive {:DOWN, ^ref, :process, ^proxy, _}

    assert {:raised, %DBConnection.OwnershipError{}} = Task.await(query)
  end

  defp proxy_of(owner) do
    %{pid: manager} = Ecto.Adapter.lookup_meta(Arbiter.Repo)

    {:owner, _ref, proxy} =
      manager |> :sys.get_state() |> Map.fetch!(:checkouts) |> Map.fetch!(owner)

    proxy
  end
end
