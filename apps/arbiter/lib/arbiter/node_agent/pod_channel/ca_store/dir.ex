defmodule Arbiter.NodeAgent.PodChannel.CAStore.Dir do
  @moduledoc """
  A `Arbiter.NodeAgent.PodChannel.CAStore` on a directory: `ca.crt` and `ca.key`
  (written `0600` before a byte of the key is, in a `0700` directory). The
  certificate is "published" simply by being there.
  """
  @behaviour Arbiter.NodeAgent.PodChannel.CAStore

  @impl true
  def load(dir) do
    with {:ok, cert} <- File.read(Path.join(dir, "ca.crt")),
         {:ok, key} <- File.read(Path.join(dir, "ca.key")) do
      {:ok, %{cert: cert, key: key}}
    else
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  @impl true
  def save(dir, %{cert: cert, key: key}) do
    key_path = Path.join(dir, "ca.key")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, io} <- File.open(key_path, [:write, :exclusive]) do
      try do
        with :ok <- File.chmod(key_path, 0o600),
             :ok <- IO.binwrite(io, key) do
          File.write(Path.join(dir, "ca.crt"), cert)
        end
      after
        File.close(io)
      end
    end
  end

  @impl true
  def publish(dir, cert_pem), do: File.write(Path.join(dir, "ca.crt"), cert_pem)
end
