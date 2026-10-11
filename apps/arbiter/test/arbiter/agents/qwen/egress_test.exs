defmodule Arbiter.Agents.Qwen.EgressTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Qwen.Egress
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.StopReason

  defp policy(sandbox \\ %{}) do
    base = SecurityPolicy.base()
    %{base | sandbox: Map.merge(base.sandbox, sandbox)}
  end

  describe "plan/2 for a local endpoint" do
    test "Ollama on loopback is a fixed-destination tunnel on the same port, no proxy host" do
      plan = Egress.plan(%{base_url: "http://127.0.0.1:11434/v1"}, policy())

      assert plan.tunnels == [{11_434, "127.0.0.1", 11_434}]
      assert plan.infra == []
    end

    test "localhost and ::1 are loopback too" do
      assert %{tunnels: [{8000, "127.0.0.1", 8000}]} =
               Egress.plan(%{base_url: "http://localhost:8000/v1"}, policy())

      assert %{tunnels: [{8000, "127.0.0.1", 8000}]} =
               Egress.plan(%{base_url: "http://[::1]:8000/v1"}, policy())
    end

    test "a policy tunnel for the same local port is not duplicated" do
      p = policy(%{egress_tunnels: ["11434:127.0.0.1:11434", "5432:127.0.0.1:5432"]})
      plan = Egress.plan(%{base_url: "http://127.0.0.1:11434/v1"}, p)

      assert Enum.count(plan.tunnels, &(elem(&1, 0) == 11_434)) == 1
      assert {5432, "127.0.0.1", 5432} in plan.tunnels
    end
  end

  describe "plan/2 for a hosted endpoint" do
    test "the endpoint's host:port is the baseline, with the scheme's default port" do
      assert %{tunnels: [], infra: ["api.example.com:443"]} =
               Egress.plan(%{base_url: "https://api.example.com/v1"}, policy())

      assert %{infra: ["llm.internal:8443"]} =
               Egress.plan(%{base_url: "https://llm.internal:8443/v1"}, policy())

      assert %{infra: ["llm.internal:80"]} =
               Egress.plan(%{base_url: "http://llm.internal/v1"}, policy())
    end

    test "a private-network endpoint also lets the proxy dial private addresses" do
      for url <- [
            "http://192.168.1.20:11434/v1",
            "http://10.0.0.5:8000/v1",
            "http://gpu-box:11434/v1",
            "http://gpu.lan:11434/v1"
          ] do
        assert %{allow_local_dial: true, tunnels: [], infra: [_]} =
                 Egress.plan(%{base_url: url}, policy()),
               url
      end

      assert %{allow_local_dial: false} =
               Egress.plan(%{base_url: "https://api.example.com/v1"}, policy())

      assert %{allow_local_dial: false} =
               Egress.plan(%{base_url: "http://8.8.8.8:80/v1"}, policy())
    end

    test "hosts are lower-cased" do
      assert %{infra: ["api.example.com:443"]} =
               Egress.plan(%{base_url: "https://API.Example.com/v1"}, policy())
    end
  end

  describe "plan/2 without a usable endpoint" do
    test "nil, blank and unparseable base URLs add nothing" do
      for endpoint <- [nil, %{}, %{base_url: ""}, %{base_url: "not a url"}, %{base_url: nil}] do
        assert %{tunnels: [], infra: []} = Egress.plan(endpoint, policy())
      end
    end
  end

  describe "baseline/2" do
    test "an open policy still enforces the endpoint plus the operator's allow_hosts" do
      p = policy(%{egress: :open, allow_hosts: ["hex.pm:443", "*.githubusercontent.com:443"]})

      assert Enum.sort(Egress.baseline(%{infra: ["api.example.com:443"]}, p)) ==
               Enum.sort(["api.example.com:443", "hex.pm:443", "*.githubusercontent.com:443"])
    end

    test ":none keeps only the infra and the toolchain registries, not other extras" do
      p = policy(%{egress: :none, allow_hosts: ["hex.pm:443", "internal.corp:443"]})
      baseline = Egress.baseline(%{infra: ["api.example.com:443"]}, p)

      assert "api.example.com:443" in baseline
      assert "hex.pm:443" in baseline
      refute "internal.corp:443" in baseline
    end
  end

  describe "enforce?/0" do
    test "defaults to true, and the app env can switch it off" do
      assert Egress.enforce?()
      Application.put_env(:arbiter, :worker_qwen_egress_enforce, false)
      on_exit(fn -> Application.delete_env(:arbiter, :worker_qwen_egress_enforce) end)
      refute Egress.enforce?()
    end
  end

  describe "denied?/1 and stop_reason/2" do
    test "a proxy 403 on CONNECT is an egress denial" do
      for line <- [
            "qwen error: Proxy response (403) !== 200 when HTTP Tunneling",
            "curl: (56) Received HTTP code 403 from proxy after CONNECT",
            "curl: (56) CONNECT tunnel failed, response 403",
            "HTTP/1.1 403 Forbidden\nX-Arbiter-Egress: not_granted",
            "qwen error: connect ENETUNREACH 93.184.216.34:443",
            "getaddrinfo EAI_AGAIN api.example.com"
          ] do
        assert Egress.denied?(line), line
      end
    end

    test "ordinary failures are not" do
      for line <- [
            "qwen error: 401 Incorrect API key provided",
            "qwen error: 429 Too Many Requests",
            "qwen error: connect ECONNREFUSED 127.0.0.1:11434",
            "ok"
          ] do
        refute Egress.denied?(line), line
      end
    end

    test "stop_reason/2 names the line and the remediation" do
      line = "qwen error: Proxy response (403) !== 200 when HTTP Tunneling"
      assert %StopReason{category: :egress_denied} = reason = Egress.stop_reason(1, line)
      assert reason.exit_status == 1
      assert reason.summary =~ "Proxy response (403)"
      assert reason.remediation =~ "allow_hosts"
    end
  end

  describe "StopReason.classify/3 for qwen" do
    test "an egress denial in the tail of a failed qwen run is :egress_denied" do
      lines = [
        "⚙ session start",
        "qwen error: Proxy response (403) !== 200 when HTTP Tunneling"
      ]

      assert %StopReason{category: :egress_denied} = StopReason.classify(1, lines, "qwen")
    end

    test "it outranks the gateway signature a tunnel failure also matches" do
      lines = ["qwen error: Tunnel connection failed: Proxy response (403) Bad gateway"]
      assert %StopReason{category: :egress_denied} = StopReason.classify(1, lines, "qwen")
    end

    test "a tool result that merely quotes a denial does not classify the run" do
      lines = ["⏴ curl: (56) CONNECT tunnel failed, response 403", "qwen error: boom"]
      refute StopReason.classify(1, lines, "qwen").category == :egress_denied
    end

    test "a clean exit, a signal death and other providers are untouched" do
      lines = ["qwen error: Proxy response (403) !== 200 when HTTP Tunneling"]

      refute StopReason.classify(0, lines, "qwen").category == :egress_denied
      assert StopReason.classify(143, lines, "qwen").category == :killed
      refute StopReason.classify(1, lines, "grok").category == :egress_denied
    end

    test "qwen's documented exit codes still win" do
      lines = ["qwen error: Proxy response (403) !== 200 when HTTP Tunneling"]
      assert StopReason.classify(41, lines, "qwen").category == :auth_expired
    end

    test "label/1 and the failure classifier know the category" do
      reason = Egress.stop_reason(1, "Proxy response (403)")
      assert StopReason.label(reason) =~ "egress"

      assert {:operational, :egress_denied} ==
               Arbiter.Loop.FailureClassifier.conclusive_stop_categories()[:egress_denied]
    end
  end
end
