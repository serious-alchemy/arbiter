defmodule Arbiter.Nodes.InstallId do
  @moduledoc """
  This install's identity for node-side reaping (`docs/design/remote-workers.md`
  §10.6): a random id persisted in `<data home>/install-id`, next to `arbiter.pid`.

  It rides in every run spec (`"install"`), becomes the `arbiter.install` label of
  the run's containers and test-services pod, and is sent with every `reap`. A node
  enrolled to two installs therefore reaps only what carries the id of the install
  asking: the other install's containers are not its to sweep.
  """

  alias Arbiter.Nodes.Agent

  @file_name "install-id"
  @id_re ~r/\A[a-z0-9]{16,64}\z/

  @doc "The install id of `home` (default: the deploy data home), minted on first use."
  @spec get(Path.t()) :: String.t()
  def get(home \\ Agent.data_home()) do
    path = Path.join(home, @file_name)

    case File.read(path) do
      {:ok, body} -> valid(String.trim(body)) || mint(home, path)
      {:error, _} -> mint(home, path)
    end
  end

  defp valid(id), do: if(Regex.match?(@id_re, id), do: id)

  defp mint(home, path) do
    id = 12 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    File.mkdir_p!(home)
    tmp = path <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, id <> "\n")
    File.rename!(tmp, path)
    id
  end
end
