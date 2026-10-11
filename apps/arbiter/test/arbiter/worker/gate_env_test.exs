defmodule Arbiter.Worker.GateEnvTest do
  @moduledoc "bd-9xcogk: the pre-push gate never carries a per-run egress proxy."
  use ExUnit.Case, async: true

  alias Arbiter.Worker.GateEnv

  test "drop_proxy/1 removes the proxy variables and a proxy-tunnelled GIT_SSH_COMMAND" do
    pairs = [
      {"HTTPS_PROXY", "http://127.0.0.1:3128"},
      {"no_proxy", "127.0.0.1"},
      {"GIT_SSH_COMMAND", "ssh -o ProxyCommand='socat - PROXY:127.0.0.1:%h:%p'"},
      {"HOME", "/work/home"}
    ]

    assert GateEnv.drop_proxy(pairs) == [{"HOME", "/work/home"}]
  end

  test "drop_proxy/1 keeps a GIT_SSH_COMMAND that is not tunnelled" do
    pairs = [{"GIT_SSH_COMMAND", "ssh -i /key"}]
    assert GateEnv.drop_proxy(pairs) == pairs
  end

  test "host_unsets/1 unsets loopback proxies only" do
    env = %{
      "HTTP_PROXY" => "http://127.0.0.1:3128",
      "https_proxy" => "http://localhost:3128",
      "ALL_PROXY" => "socks5://[::1]:1080",
      "NO_PROXY" => "127.0.0.1",
      "HTTPS_PROXY" => "http://proxy.corp.example:8080",
      "no_proxy" => "localhost,.corp.example",
      "HOME" => "/home/x"
    }

    assert env |> GateEnv.host_unsets() |> Enum.sort() ==
             Enum.sort([
               {"HTTP_PROXY", false},
               {"https_proxy", false},
               {"ALL_PROXY", false},
               {"NO_PROXY", false}
             ])
  end
end
