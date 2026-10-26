defmodule Arbiter.Worker.CliFetcher.Upstream do
  @moduledoc """
  The only module of the CLI fetcher that opens a network connection: npm
  registry reads and downloads, and GitHub release reads and downloads.

  It is called from `Arbiter.Worker.CliFetcher.fetch/3` / `latest/2` and from
  the daily bump (`Arbiter.Worker.CliFetcher.Scheduler`), and from nowhere on a
  dispatch, spawn or publish path: `CliFetcherNoRuntimeFetchTest` fails the build
  if any other module references it. Only the publisher reads the verified cache.

  Every call takes `opts[:req_options]` (merged into the `Req` request; tests
  inject `plug: {Req.Test, ...}`), `opts[:registry]` (default
  `https://registry.npmjs.org`) and `opts[:github_api]` (default
  `https://api.github.com`, `ARB_GITHUB_API` overrides).
  """

  @registry "https://registry.npmjs.org"
  @github_api "https://api.github.com"
  @max_download 1_073_741_824
  @json_timeout 30_000
  @download_timeout 300_000

  @doc "The base URL of the npm registry."
  @spec registry(keyword()) :: String.t()
  def registry(opts), do: opts |> Keyword.get(:registry, @registry) |> String.trim_trailing("/")

  @doc "GET `url` as JSON."
  @spec get_json(String.t(), keyword(), [{String.t(), String.t()}]) ::
          {:ok, term()} | {:error, term()}
  def get_json(url, opts, extra_headers \\ []) do
    req =
      [
        method: :get,
        url: url,
        headers: [{"accept", "application/json"} | extra_headers],
        receive_timeout: @json_timeout,
        retry: false
      ] ++ Keyword.get(opts, :req_options, [])

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: 200}} -> {:error, {:bad_response, url}}
      {:ok, %Req.Response{status: 404}} -> {:error, {:not_found, url}}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status, url}}
      {:error, reason} -> {:error, {:request_failed, url, reason}}
    end
  end

  @doc "GET an npm document, `path` being `@scope/name/<version>` or similar."
  @spec npm_json(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def npm_json(path, opts), do: get_json(registry(opts) <> "/" <> path, opts)

  @doc """
  Download `url` to `dest` (a file path), capped at 1 GiB. https URLs only; `headers` are sent as given.
  """
  @spec download(String.t(), Path.t(), keyword(), [{String.t(), String.t()}]) ::
          :ok | {:error, term()}
  def download(url, dest, opts, headers \\ []) do
    with :ok <- https(url) do
      File.mkdir_p!(Path.dirname(dest))
      file = File.open!(dest, [:write, :binary])
      written = :counters.new(1, [])

      sink = fn {:data, data}, {req, resp} ->
        :counters.add(written, 1, byte_size(data))

        if :counters.get(written, 1) > @max_download do
          {:halt, {req, resp}}
        else
          IO.binwrite(file, data)
          {:cont, {req, resp}}
        end
      end

      req =
        [
          method: :get,
          url: url,
          headers: headers,
          into: sink,
          raw: true,
          decode_body: false,
          receive_timeout: @download_timeout,
          retry: false
        ] ++ Keyword.get(opts, :req_options, [])

      result = Req.request(req)
      File.close(file)
      outcome = download_outcome(result, :counters.get(written, 1), url)
      if outcome != :ok, do: File.rm(dest)
      outcome
    end
  end

  defp download_outcome(_result, bytes, url) when bytes > @max_download,
    do: {:error, {:too_big, url}}

  defp download_outcome({:ok, %Req.Response{status: 200}}, _bytes, _url), do: :ok

  defp download_outcome({:ok, %Req.Response{status: status}}, _bytes, url),
    do: {:error, {:http, status, url}}

  defp download_outcome({:error, reason}, _bytes, url),
    do: {:error, {:request_failed, url, reason}}

  @doc "The GitHub API base URL."
  @spec github_api(keyword()) :: String.t()
  def github_api(opts) do
    case Keyword.get(opts, :github_api) || System.get_env("ARB_GITHUB_API") do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> @github_api
    end
  end

  @doc "Headers for GitHub requests; `GITHUB_TOKEN`, when set, authenticates a private repo."
  @spec github_headers() :: [{String.t(), String.t()}]
  def github_headers do
    base = [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]

    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | base]

      _ ->
        base
    end
  end

  defp https(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _ -> {:error, {:insecure_url, url}}
    end
  end
end
