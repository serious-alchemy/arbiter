defmodule Arbiter.NodeAgent.PodChannel.CAStore do
  @moduledoc """
  Where the per-install CA lives between boots (`docs/design/remote-workers.md`
  §16 K§2.4, K§12). In a cluster it is the Secret `arbiter-controller-ca`
  (private key, controller-only RBAC) plus the ConfigMap `arbiter-ca` (public
  certificate, mounted into worker pods); the controller (K5) supplies that
  implementation. `Arbiter.NodeAgent.PodChannel.CAStore.Dir` is the plain
  filesystem one.

  **Only the CA is ever handed to a store.** Leaf certificates, their keys and
  every per-run secret stay in the controller's memory
  (`Arbiter.NodeAgent.PodChannel.Runs`): per-run material never becomes a
  Kubernetes object.

  A store is a `{module, arg}`; every callback gets `arg` first.
  """

  @type t :: {module(), term()}
  @type material :: %{cert: binary(), key: binary()}

  @doc "The stored CA as PEM, or `:none` on first boot."
  @callback load(arg :: term()) :: {:ok, material()} | :none | {:error, term()}

  @doc "Persist a new CA (certificate and private key, PEM)."
  @callback save(arg :: term(), material()) :: :ok | {:error, term()}

  @doc "Publish the public certificate (never the key) for pods to mount."
  @callback publish(arg :: term(), cert_pem :: binary()) :: :ok | {:error, term()}
end
