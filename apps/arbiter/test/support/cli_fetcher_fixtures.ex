defmodule Arbiter.Worker.CliFetcher.Fixtures do
  @moduledoc false
  # Stubbed upstreams for the CLI fetcher tests: a fake npm registry
  # (`https://registry.test`) and a fake GitHub (`https://api.github.test`)
  # served through `Req.Test`. Every request reaches the test process as
  # `{:upstream, path}`, so a test can assert what was (not) fetched.

  @registry "https://registry.test"
  @github "https://api.github.test"
  @stub Arbiter.Worker.CliFetcher.HTTP

  def stub_name, do: @stub

  def base_opts(root, extra \\ []) do
    Keyword.merge(
      [
        root: root,
        platform: "linux-x64",
        registry: @registry,
        github_api: @github,
        release_repo: "acme/arbiter",
        req_options: [plug: {Req.Test, @stub}, retry: false]
      ],
      extra
    )
  end

  @doc "A gzipped tar of `[{path, content, mode}]`."
  def tgz(files) do
    dir = Path.join(System.tmp_dir!(), "cli-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    out = Path.join(dir, "out.tgz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(out), [:write, :compressed])

    for {path, content, mode} <- files do
      src = Path.join(dir, "src-#{System.unique_integer([:positive])}")
      File.write!(src, content)
      File.chmod!(src, mode)
      :ok = :erl_tar.add(tar, String.to_charlist(src), String.to_charlist(path), [])
    end

    :ok = :erl_tar.close(tar)
    bin = File.read!(out)
    File.rm_rf!(dir)
    bin
  end

  def sri(bin), do: "sha512-" <> Base.encode64(:crypto.hash(:sha512, bin))
  def sha256(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)

  @doc "Install `routes` (`%{path => {status, content_type, body}}`) as the upstream."
  def serve(routes) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:upstream, conn.request_path})

      case Map.get(routes, conn.request_path) do
        nil ->
          Plug.Conn.send_resp(conn, 404, "not found")

        {status, body} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, body)

        {status, content_type, body} ->
          conn
          |> Plug.Conn.put_resp_content_type(content_type)
          |> Plug.Conn.send_resp(status, body)
      end
    end)

    routes
  end

  def json(map), do: {200, "application/json", Jason.encode!(map)}

  # ---- claude -----------------------------------------------------------

  def claude_binary(version), do: "CLAUDE-ELF-#{version}"

  @doc "Routes for these claude versions; `latest` is the `latest` dist-tag."
  def claude_routes(versions, latest \\ nil) do
    base = %{
      "/-/package/@anthropic-ai/claude-code/dist-tags" =>
        json(%{"latest" => latest || List.last(versions), "stable" => hd(versions)})
    }

    Enum.reduce(versions, base, fn ver, acc ->
      tarball =
        tgz([
          {"package/claude", claude_binary(ver), 0o755},
          {"package/package.json", ~s({"name":"x"}), 0o644}
        ])

      pkg = "@anthropic-ai/claude-code-linux-x64"

      acc
      |> Map.put(
        "/@anthropic-ai/claude-code/#{ver}",
        json(%{
          "version" => ver,
          "optionalDependencies" => %{
            "@anthropic-ai/claude-code-linux-x64" => ver,
            "@anthropic-ai/claude-code-linux-arm64" => ver,
            "@anthropic-ai/claude-code-linux-x64-musl" => ver
          }
        })
      )
      |> Map.put(
        "/#{pkg}/#{ver}",
        json(%{
          "version" => ver,
          "dist" => %{
            "tarball" => "#{@registry}/#{pkg}/-/claude-code-linux-x64-#{ver}.tgz",
            "integrity" => sri(tarball)
          }
        })
      )
      |> Map.put(
        "/#{pkg}/-/claude-code-linux-x64-#{ver}.tgz",
        {200, "application/octet-stream", tarball}
      )
    end)
  end

  @doc "Replace the claude tarball of `ver` (and the integrity its document publishes)."
  def with_claude_tarball(routes, ver, tarball) do
    pkg = "/@anthropic-ai/claude-code-linux-x64"
    doc_path = "#{pkg}/#{ver}"
    {200, _, doc} = Map.fetch!(routes, doc_path)
    doc = doc |> Jason.decode!() |> put_in(["dist", "integrity"], sri(tarball))

    routes
    |> Map.put(doc_path, json(doc))
    |> Map.put(
      "#{pkg}/-/claude-code-linux-x64-#{ver}.tgz",
      {200, "application/octet-stream", tarball}
    )
  end

  @doc "A gzipped tar built by hand, so member names are stored verbatim (`..` included)."
  def raw_tgz(files) do
    blocks =
      for {name, content} <- files do
        header = tar_header(name, byte_size(content))
        pad = rem(512 - rem(byte_size(content), 512), 512)
        [header, content, :binary.copy(<<0>>, pad)]
      end

    :zlib.gzip(IO.iodata_to_binary([blocks, :binary.copy(<<0>>, 1024)]))
  end

  defp tar_header(name, size) do
    fields = [
      String.pad_trailing(name, 100, <<0>>),
      "0000644\0",
      "0000000\0",
      "0000000\0",
      String.pad_leading(Integer.to_string(size, 8), 11, "0") <> "\0",
      "00000000000\0",
      "        ",
      "0",
      String.duplicate(<<0>>, 100),
      "ustar\0" <> "00",
      String.duplicate(<<0>>, 32),
      String.duplicate(<<0>>, 32),
      "0000000\0",
      "0000000\0",
      String.duplicate(<<0>>, 155),
      String.duplicate(<<0>>, 12)
    ]

    header = IO.iodata_to_binary(fields)
    sum = header |> :binary.bin_to_list() |> Enum.sum()
    chk = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> "\0 "
    binary_part(header, 0, 148) <> chk <> binary_part(header, 156, 512 - 156)
  end

  # ---- codex ------------------------------------------------------------

  @triple "x86_64-unknown-linux-musl"

  def codex_files(ver) do
    v = "package/vendor/#{@triple}"

    [
      {"package/package.json", ~s({"name":"@openai/codex"}), 0o644},
      {"#{v}/bin/codex", "CODEX-ELF-#{ver}", 0o755},
      {"#{v}/bin/codex-code-mode-host", "HOST-#{ver}", 0o755},
      {"#{v}/codex-path/rg", "RG", 0o755},
      {"#{v}/codex-resources/bwrap", "BWRAP", 0o755},
      {"#{v}/codex-resources/voice/bin/codex-voice-host", "VOICE-HOST", 0o755},
      {"#{v}/codex-resources/voice/lib/libopus.so.0", "OPUS", 0o644},
      {"#{v}/codex-resources/voice/manifest.json", "{}", 0o644}
    ]
  end

  @doc "Routes for these codex versions (the `<ver>-linux-x64` platform packages)."
  def codex_routes(versions, latest \\ nil, extra_tags \\ %{}) do
    base = %{
      "/-/package/@openai/codex/dist-tags" =>
        json(Map.merge(%{"latest" => latest || List.last(versions)}, extra_tags))
    }

    Enum.reduce(versions, base, fn ver, acc ->
      tarball = tgz(codex_files(ver))

      acc
      |> Map.put(
        "/@openai/codex/#{ver}-linux-x64",
        json(%{
          "version" => "#{ver}-linux-x64",
          "dist" => %{
            "tarball" => "#{@registry}/@openai/codex/-/codex-#{ver}-linux-x64.tgz",
            "integrity" => sri(tarball)
          }
        })
      )
      |> Map.put(
        "/@openai/codex/-/codex-#{ver}-linux-x64.tgz",
        {200, "application/octet-stream", tarball}
      )
    end)
  end

  # ---- arb --------------------------------------------------------------

  def arb_bytes(version), do: "ARB-ESCRIPT-#{version}"

  def arb_routes(version, opts \\ []) do
    bytes = Keyword.get(opts, :bytes, arb_bytes(version))
    sha = Keyword.get(opts, :sha256, sha256(arb_bytes(version)))

    release = %{
      "tag_name" => "v#{version}",
      "assets" => [
        %{"name" => "arb", "browser_download_url" => "https://github.test/dl/#{version}/arb"},
        %{
          "name" => "arb.sha256",
          "browser_download_url" => "https://github.test/dl/#{version}/arb.sha256"
        }
      ]
    }

    %{
      "/repos/acme/arbiter/releases/tags/v#{version}" => json(release),
      "/dl/#{version}/arb" => {200, "application/octet-stream", bytes},
      "/dl/#{version}/arb.sha256" => {200, "text/plain", "#{sha}  arb\n"}
    }
  end
end
