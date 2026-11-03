defmodule Arbiter.NodeAgent.RegistryProbeTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.RegistryProbe

  defp plug(statuses) do
    fn conn ->
      case Map.fetch(statuses, conn.host) do
        {:ok, :down} -> Plug.Conn.send_resp(conn, 503, "")
        {:ok, status} -> Plug.Conn.send_resp(conn, status, "")
        :error -> raise "connection refused"
      end
    end
  end

  test "200 and 401 from /v2/ are reachable; anything else, or no answer, is unreachable" do
    opts = [req_options: [plug: plug(%{"open.io" => 200, "auth.io" => 401, "bad.io" => :down})]]

    assert RegistryProbe.probe(["open.io", "auth.io", "bad.io", "gone.io"], opts) == %{
             "open.io" => "reachable",
             "auth.io" => "reachable",
             "bad.io" => "unreachable",
             "gone.io" => "unreachable"
           }
  end

  test "no hosts, no probe" do
    assert RegistryProbe.probe([], []) == %{}
  end

  test "hosts are bounded and non-strings ignored" do
    opts = [req_options: [plug: plug(%{"a.io" => 200})]]
    assert RegistryProbe.probe(["a.io", 3, nil], opts) == %{"a.io" => "reachable"}
  end
end
