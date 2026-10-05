defmodule ArbiterProFake.BoardHoldGate do
  @moduledoc false
  @behaviour Arbiter.Quota.Gate

  @impl true
  def check(_task, _quota, _workspace, _opts), do: :allow

  @impl true
  def board_hold(_quota, _policy, _opts), do: {:hold, "fake gate says hold"}
end

defmodule ArbiterProFake.BoardHoldExtension do
  @moduledoc false
  @behaviour Arbiter.Extension

  @impl true
  def contributions, do: [{:quota_gate, "fake_hold", ArbiterProFake.BoardHoldGate}]
end

defmodule Arbiter.Board.SnapshotQuotaGateTest do
  @moduledoc """
  Seams #6: `Board.Snapshot.quota_hold/2` asks the workspace's *resolved* quota
  gate, so two workspaces on different gates get different board holds.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Extensions
  alias Arbiter.Tasks.Workspace

  setup do
    Extensions.load!([ArbiterProFake.BoardHoldExtension])
    on_exit(fn -> Extensions.load!([]) end)
    :ok
  end

  defp workspace!(quota) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "sqg-#{n}", prefix: "sqg#{n}", config: %{"quota" => quota}})
  end

  test "the board holds through the gate the workspace selected, not core's logic" do
    held = workspace!(%{"gate" => "fake_hold"})
    plain = workspace!(%{})

    assert Snapshot.quota_hold(held.id) == {:hold, "fake gate says hold"}
    assert Snapshot.quota_hold(plain.id) == :ok
  end

  test "a core gate callback fails open without a snapshot" do
    assert Arbiter.Quota.Gate.Throttle.board_hold(nil, {nil, nil}, []) == :ok
    assert Arbiter.Quota.Gate.Continue.board_hold(nil, {nil, nil}, []) == :ok
  end

  test "the global :gate override cannot install a non-core gate" do
    put_app_env(:arbiter, :quota, gate: ArbiterProFake.BoardHoldGate)
    ws = workspace!(%{})

    assert Arbiter.Quota.gate_for_workspace(ws) == Arbiter.Quota.Gate.Throttle
    assert Snapshot.quota_hold(ws.id) == :ok
  end
end
