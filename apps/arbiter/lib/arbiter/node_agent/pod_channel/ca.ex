defmodule Arbiter.NodeAgent.PodChannel.CA do
  @moduledoc """
  The per-install CA (`docs/design/remote-workers.md` §16 K§9.2): an EC P-256
  CA created on the controller's first boot, kept in a
  `Arbiter.NodeAgent.PodChannel.CAStore`, valid for five years. Every later boot
  reads the same CA, so pods' mounted trust anchor keeps working across a
  controller restart.

  A stored CA that is expired, damaged or whose key does not match is an
  **error**, not a reason to mint a replacement: replacing it would silently
  orphan every running pod's identity. The operator deletes the Secret to start
  over.
  """

  alias Arbiter.NodeAgent.PodChannel.Cert

  @ttl_days 5 * 365
  @skew_s 60

  @doc """
  Load the CA from `store`, creating (and saving) it on first boot, and publish
  the public certificate. Options: `:now` (a `DateTime`, for tests).
  """
  @spec load_or_create(Arbiter.NodeAgent.PodChannel.CAStore.t(), keyword()) ::
          {:ok, Cert.t()} | {:error, term()}
  def load_or_create({mod, arg}, opts \\ []) do
    with {:ok, ca} <- existing_or_new(mod, arg, opts),
         :ok <- publish(mod, arg, ca) do
      {:ok, ca}
    end
  end

  defp existing_or_new(mod, arg, opts) do
    case mod.load(arg) do
      {:ok, %{cert: cert, key: key}} -> Cert.load_ca(cert, key)
      :none -> create(mod, arg, opts)
      {:error, reason} -> {:error, {:ca_load_failed, reason}}
    end
  end

  defp create(mod, arg, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    ca = Cert.ca(DateTime.add(now, -@skew_s), DateTime.add(now, @ttl_days * 86_400))

    case mod.save(arg, %{cert: Cert.pem_cert(ca.der), key: Cert.pem_key(ca.key)}) do
      :ok -> {:ok, ca}
      {:error, reason} -> {:error, {:ca_save_failed, reason}}
    end
  end

  defp publish(mod, arg, ca) do
    case mod.publish(arg, Cert.pem_cert(ca.der)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ca_publish_failed, reason}}
    end
  end
end
