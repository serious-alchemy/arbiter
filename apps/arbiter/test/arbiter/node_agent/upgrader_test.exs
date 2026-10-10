defmodule Arbiter.NodeAgent.UpgraderTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Upgrader

  defp start_upgrader(version) do
    config = %Config{version: version, node_home: System.tmp_dir!()}
    name = :"upgrader_#{System.unique_integer([:positive])}"
    start_supervised!({Upgrader, config: config, name: name, status: :no_status})
    name
  end

  @sha String.duplicate("a", 64)

  test "a request for the running version is ignored with or without a leading v" do
    up = start_upgrader("0.2.40")

    assert :ignored = Upgrader.request(up, %{"version" => "v0.2.40", "sha256" => @sha})
    assert :ignored = Upgrader.request(up, %{"version" => "0.2.40", "sha256" => @sha})
  end

  test "a running `v`-prefixed version also matches a bare request" do
    up = start_upgrader("v0.2.40")
    assert :ignored = Upgrader.request(up, %{"version" => "0.2.40", "sha256" => @sha})
  end
end
