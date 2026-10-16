defmodule Arbiter.NodeAgent.K8s.ApiReachTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ApiReach

  defp refused, do: {:transport, %Req.TransportError{reason: :econnrefused}}

  test "a refused or timed-out connection to the API server is unreachable" do
    assert ApiReach.unreachable?(refused())
    assert ApiReach.unreachable?({:transport, %Req.TransportError{reason: :timeout}})
    assert ApiReach.unreachable?({:transport, %Req.TransportError{reason: :ehostunreach}})
  end

  test "an API answer, however negative, is reachable" do
    refute ApiReach.unreachable?(:unauthorized)
    refute ApiReach.unreachable?({:forbidden, "secrets is forbidden"})
    refute ApiReach.unreachable?(:not_found)
    refute ApiReach.unreachable?({:http, 500, "boom"})
    refute ApiReach.unreachable?({:enroll_failed, refused()})
  end

  test "the message names the cause, the post-DNAT trap, the fix and the runbook" do
    message = ApiReach.message(refused())

    assert message =~ "cannot reach the Kubernetes API server"
    assert message =~ "econnrefused"
    assert message =~ "controller-egress"
    assert message =~ "after DNAT"
    assert message =~ "kubectl get endpoints kubernetes"
    assert message =~ "--api-cidrs"
    assert message =~ "docs/remote-workers-k8s-runbook.md"
  end
end
