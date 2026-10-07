defmodule Arbiter.NodeAgent.Transcripts do
  @moduledoc """
  The node half of transcript sync (`docs/design/remote-workers.md` §7.6): pack the
  run's session JSONL (`<config_dir>/projects/**/*.jsonl`, subagents included) into
  a gzipped tar and `PUT /nodes/runs/<run>/transcripts`. Only regular `*.jsonl`
  files are packed (links are never followed or stored), so what the primary's
  sanitising extractor (`Arbiter.Nodes.Transcripts`) accepts is what is sent;
  `.credentials.json` and the rest of the config dir stay on the node.
  """

  alias Arbiter.NodeAgent.Config

  @doc "Tar `config_dir`'s transcripts into `dest`. `{:ok, %{files, bytes}}`."
  @spec pack(Path.t(), Path.t()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def pack(config_dir, dest) do
    files = config_dir |> Path.join("projects") |> walk() |> Enum.sort()

    entries =
      for path <- files do
        {config_dir |> Path.join("") |> then(&Path.relative_to(path, &1)) |> String.to_charlist(),
         String.to_charlist(path)}
      end

    File.mkdir_p!(Path.dirname(dest))

    case :erl_tar.create(String.to_charlist(dest), entries, [:compressed]) do
      :ok -> {:ok, %{files: length(files), bytes: Enum.sum(for p <- files, do: size(p))}}
      {:error, reason} -> {:error, {:pack_failed, reason}}
    end
  end

  defp size(path) do
    case File.lstat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # Regular `.jsonl` files, not following any link.
  defp walk(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        dir |> File.ls!() |> Enum.flat_map(&walk(Path.join(dir, &1)))

      {:ok, %File.Stat{type: :regular}} ->
        if String.ends_with?(dir, ".jsonl"), do: [dir], else: []

      _ ->
        []
    end
  end

  @doc "Pack and `PUT` the run's transcripts. `{:ok, response}` or `{:error, reason}`."
  @spec upload(Config.t(), String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def upload(%Config{} = config, run, config_dir) do
    dest = Path.join([config.node_home, "runs", run, "transcripts.tar.gz"])

    try do
      with {:ok, %{files: n}} when n > 0 <- pack(config_dir, dest),
           {:ok, %File.Stat{size: bytes}} <- File.stat(dest) do
        put_tar(config, run, dest, bytes)
      else
        {:ok, %{files: 0}} -> {:ok, %{"files" => 0}}
        {:error, _} = error -> error
      end
    after
      File.rm(dest)
    end
  end

  @doc "`PUT` the file at `path` (`bytes` long) for `run`: `{:ok, body}` or `{:error, reason}`."
  @spec put_tar(Config.t(), String.t(), Path.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def put_tar(config, run, path, bytes) do
    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/runs/#{run}/transcripts"),
          method: :put,
          headers: [
            {"authorization", "Bearer " <> config.credential},
            {"content-type", "application/gzip"},
            {"content-length", Integer.to_string(bytes)}
          ],
          body: File.stream!(path, 65_536),
          retry: false,
          receive_timeout: 600_000
        ] ++ (config.req_options || [])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:rejected, status, body}}
      {:error, reason} -> {:error, {:upload_failed, reason}}
    end
  end
end
