defmodule Arbiter.NodeAgent.Files do
  @moduledoc """
  Content-addressed files the primary hands a node (`docs/design/remote-workers.md`
  §7.3): the provider CLI and `arb` that a run mounts read-only at
  `/opt/arbiter/cli`. `GET /nodes/files/<sha256>` with the node credential;
  cached under `<node_home>/files/<sha12>/<name>`; the hash is **verified**
  before the file is ever executable, so a wrong or tampered body is deleted and
  refused. A cached file is re-hashed on use (a few MiB, once per run).
  """

  alias Arbiter.NodeAgent.Config

  @sha_re ~r/\A[0-9a-f]{64}\z/
  @name_re ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @spec dir(Config.t(), String.t()) :: Path.t()
  def dir(%Config{node_home: home}, sha), do: Path.join([home, "files", binary_part(sha, 0, 12)])

  @doc "The verified local path of `sha`, fetching it first if the node does not have it."
  @spec ensure(Config.t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(%Config{} = config, sha, name) when is_binary(sha) and is_binary(name) do
    with true <- Regex.match?(@sha_re, sha) or {:error, :bad_sha256},
         true <- Regex.match?(@name_re, name) or {:error, :bad_name} do
      path = Path.join(dir(config, sha), name)

      if File.regular?(path) and hash(path) == sha,
        do: {:ok, path},
        else: fetch(config, sha, path)
    end
  end

  defp fetch(config, sha, path) do
    dir = Path.dirname(path)
    part = path <> ".part"

    with :ok <- File.mkdir_p(dir),
         :ok <- download(config, sha, part),
         :ok <- verify(part, sha),
         :ok <- File.chmod(part, 0o755),
         :ok <- File.rename(part, path) do
      {:ok, path}
    else
      {:error, _} = error ->
        File.rm(part)
        error
    end
  end

  defp download(config, sha, part) do
    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/files/" <> sha),
          headers: [{"authorization", "Bearer " <> config.credential}],
          decode_body: false,
          into: File.stream!(part),
          receive_timeout: 120_000
        ] ++ (config.req_options || [])
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:download_failed, reason}}
    end
  end

  defp verify(path, sha), do: if(hash(path) == sha, do: :ok, else: {:error, :sha256_mismatch})

  defp hash(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
