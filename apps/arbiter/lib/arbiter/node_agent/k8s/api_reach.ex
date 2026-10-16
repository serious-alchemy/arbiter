defmodule Arbiter.NodeAgent.K8s.ApiReach do
  @moduledoc """
  Names the failure of a controller that cannot connect to the Kubernetes API server.

  The usual cause is the `controller-egress` NetworkPolicy
  (`Arbiter.NodeAgent.K8s.InstallManifest`): a CNI that evaluates egress *after* DNAT
  (k3s's kube-router) sees the connection to the `kubernetes` Service as one to the API
  server's node address, which the rule only allows when it was rendered with `api_cidrs`.
  The connection is then refused, and without this the operator reads a bare
  `{:transport, %Req.TransportError{reason: :econnrefused}}` and nothing else.

  Only a transport failure counts: an API answer (401, 403, 404 ...) proves the server was
  reached, and a transport failure of some *other* peer (`{:enroll_failed, _}`, the
  primary) is not the API server's.
  """

  @doc "Whether `reason` (a `Client` error) is a failure to connect to the API server."
  @spec unreachable?(term()) :: boolean()
  def unreachable?({:transport, %{reason: reason}}) when is_atom(reason), do: true
  def unreachable?(_other), do: false

  @doc "The operator-facing message for an `unreachable?/1` `reason`."
  @spec message(term()) :: String.t()
  def message(reason) do
    "cannot reach the Kubernetes API server (#{cause(reason)}). Check the controller-egress " <>
      "NetworkPolicy: a CNI that applies egress rules after DNAT (k3s's kube-router) matches the " <>
      "API server's node address, not the kubernetes Service address. Find it with " <>
      "`kubectl get endpoints kubernetes -o jsonpath='{.subsets[*].addresses[*].ip}'` and render the " <>
      "install again with api_cidrs (`arb node add --kind cluster --api-cidrs <ip>/32`, or the Add " <>
      "node form). See docs/remote-workers-k8s-runbook.md."
  end

  defp cause({:transport, %{reason: reason}}) when is_atom(reason), do: Atom.to_string(reason)
  defp cause(_other), do: "connection failed"
end
