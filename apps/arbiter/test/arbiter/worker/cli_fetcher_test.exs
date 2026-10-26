defmodule Arbiter.Worker.CliFetcherTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Fixtures

  @moduletag :tmp_dir

  defp opts(ctx, extra \\ []), do: Fixtures.base_opts(Path.join(ctx.tmp_dir, "cli-cache"), extra)

  defp flush_hits(acc \\ []) do
    receive do
      {:upstream, path} -> flush_hits([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "ensure/3 for claude" do
    test "fetches a pinned version once into the content-addressed cache", ctx do
      Fixtures.serve(Fixtures.claude_routes(["2.1.310"]))

      assert {:ok, entry} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
      assert entry.name == "claude"
      assert entry.version == "2.1.310"
      assert entry.main == "claude"
      assert [%{path: "claude", sha256: sha, size: size, mode: 0o755}] = entry.files
      assert sha == Fixtures.sha256(Fixtures.claude_binary("2.1.310"))
      assert size == byte_size(Fixtures.claude_binary("2.1.310"))
      assert File.read!(Cache.object_path(entry, "claude")) == Fixtures.claude_binary("2.1.310")

      first = flush_hits()
      assert "/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.310.tgz" in first

      # The second ensure is answered from the cache: no upstream request at all.
      assert {:ok, ^entry} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
      assert flush_hits() == []
    end

    test "a checksum mismatch is refused and nothing is cached", ctx do
      routes = Fixtures.claude_routes(["2.1.310"])
      tarball_path = "/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.310.tgz"

      tampered =
        Fixtures.tgz([{"package/claude", "EVIL-BINARY", 0o755}])

      Fixtures.serve(Map.put(routes, tarball_path, {200, "application/octet-stream", tampered}))

      assert {:error, {:integrity_mismatch, _}} =
               CliFetcher.ensure("claude", "2.1.310", opts(ctx))

      assert :error = Cache.lookup("claude", "2.1.310", opts(ctx))

      refute File.exists?(Path.join(opts(ctx)[:root], "objects")) and
               Path.wildcard(Path.join(opts(ctx)[:root], "objects/**/*"))
               |> Enum.any?(&File.regular?/1)
    end

    test "a version document without dist.integrity is refused", ctx do
      routes = Fixtures.claude_routes(["2.1.310"])

      doc = %{
        "version" => "2.1.310",
        "dist" => %{
          "tarball" =>
            "https://registry.test/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.310.tgz"
        }
      }

      Fixtures.serve(
        Map.put(routes, "/@anthropic-ai/claude-code-linux-x64/2.1.310", Fixtures.json(doc))
      )

      assert {:error, :no_integrity} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
    end

    test "a tarball URL on another host is refused", ctx do
      routes = Fixtures.claude_routes(["2.1.310"])

      doc = %{
        "version" => "2.1.310",
        "dist" => %{
          "tarball" => "https://evil.example/claude.tgz",
          "integrity" => Fixtures.sri("x")
        }
      }

      Fixtures.serve(
        Map.put(routes, "/@anthropic-ai/claude-code-linux-x64/2.1.310", Fixtures.json(doc))
      )

      assert {:error, {:untrusted_tarball_host, "evil.example"}} =
               CliFetcher.ensure("claude", "2.1.310", opts(ctx))
    end

    test "refuses a version that is not a plain x.y.z", ctx do
      Fixtures.serve(%{})

      assert {:error, {:bad_version, "2.1.0-rc.1"}} =
               CliFetcher.ensure("claude", "2.1.0-rc.1", opts(ctx))

      assert {:error, {:unknown_cli, "grok"}} = CliFetcher.ensure("grok", "1.0.0", opts(ctx))
      assert flush_hits() == []
    end
  end

  describe "ensure/3 for codex" do
    test "excludes the voice host from the fetched set", ctx do
      Fixtures.serve(Fixtures.codex_routes(["0.164.0"]))

      assert {:ok, entry} = CliFetcher.ensure("codex", "0.164.0", opts(ctx))
      assert entry.main == "bin/codex"

      paths = Enum.map(entry.files, & &1.path) |> Enum.sort()

      assert paths ==
               ["bin/codex", "bin/codex-code-mode-host", "codex-path/rg", "codex-resources/bwrap"]

      refute Enum.any?(paths, &String.contains?(&1, "voice"))

      # ...and the voice bytes are not in the object store either.
      stored =
        Path.join(opts(ctx)[:root], "objects/**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&File.read!/1)

      refute "VOICE-HOST" in stored
      refute "OPUS" in stored
      assert "CODEX-ELF-0.164.0" in stored
    end

    test "unchanged files are stored once across versions (content addressing)", ctx do
      Fixtures.serve(Fixtures.codex_routes(["0.163.0", "0.164.0"]))
      assert {:ok, a} = CliFetcher.ensure("codex", "0.163.0", opts(ctx))
      assert {:ok, b} = CliFetcher.ensure("codex", "0.164.0", opts(ctx))

      rg = fn e -> Enum.find(e.files, &(&1.path == "codex-path/rg")) end
      assert Cache.object_path(a, "codex-path/rg") == Cache.object_path(b, "codex-path/rg")
      assert rg.(a).sha256 == rg.(b).sha256
    end
  end

  describe "ensure/3 for arb" do
    test "fetches the release asset and verifies the published .sha256", ctx do
      Fixtures.serve(Fixtures.arb_routes("1.2.3"))

      assert {:ok, entry} = CliFetcher.ensure("arb", "1.2.3", opts(ctx))
      assert [%{path: "arb", mode: 0o755}] = entry.files
      assert File.read!(Cache.object_path(entry, "arb")) == Fixtures.arb_bytes("1.2.3")
    end

    test "a .sha256 mismatch is refused", ctx do
      Fixtures.serve(Fixtures.arb_routes("1.2.3", bytes: "TAMPERED"))

      assert {:error, {:integrity_mismatch, _}} = CliFetcher.ensure("arb", "1.2.3", opts(ctx))
      assert :error = Cache.lookup("arb", "1.2.3", opts(ctx))
    end

    test "fails closed when this build has no release repo", ctx do
      Fixtures.serve(%{})

      assert {:error, :no_release_repo} =
               CliFetcher.ensure("arb", "1.2.3", opts(ctx, release_repo: nil))
    end
  end

  describe "latest/2" do
    test "is the latest dist-tag when it is a plain x.y.z", ctx do
      Fixtures.serve(Fixtures.claude_routes(["2.1.308", "2.1.310"], "2.1.310"))
      assert {:ok, "2.1.310"} = CliFetcher.latest("claude", opts(ctx))
    end

    test "never returns a prerelease: falls back to the newest stable in the version list", ctx do
      routes =
        Map.merge(Fixtures.codex_routes(["0.164.0"], "0.165.0-alpha.1"), %{
          "/@openai/codex" =>
            Fixtures.json(%{
              "dist-tags" => %{"latest" => "0.165.0-alpha.1"},
              "versions" => %{
                "0.163.0" => %{},
                "0.164.0" => %{},
                "0.164.0-linux-x64" => %{},
                "0.165.0-alpha.1" => %{}
              }
            })
        })

      Fixtures.serve(routes)
      assert {:ok, "0.164.0"} = CliFetcher.latest("codex", opts(ctx))
    end

    test "arb has no upstream latest: it follows the running release", ctx do
      assert {:error, {:no_upstream_latest, "arb"}} = CliFetcher.latest("arb", opts(ctx))
    end
  end

  describe "hostile archives" do
    test "a member that climbs out of the archive is refused before extraction", ctx do
      evil = Fixtures.raw_tgz([{"package/../../escape", "x"}, {"package/claude", "ok"}])

      Fixtures.serve(
        Fixtures.claude_routes(["2.1.310"])
        |> Fixtures.with_claude_tarball("2.1.310", evil)
      )

      assert {:error, {:unsafe_path, _}} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
      refute File.exists?(Path.join(ctx.tmp_dir, "escape"))
      assert :error = Cache.lookup("claude", "2.1.310", opts(ctx))
    end
  end

  describe "cache" do
    test "a damaged object fails verification and is refetched", ctx do
      Fixtures.serve(Fixtures.claude_routes(["2.1.310"]))
      {:ok, entry} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
      assert :ok = Cache.verify(entry)

      path = Cache.object_path(entry, "claude")
      File.chmod!(path, 0o644)
      File.write!(path, "CORRUPTED-BYTES")
      assert {:error, {:corrupt, "claude"}} = Cache.verify(entry)

      flush_hits()
      assert {:ok, again} = CliFetcher.ensure("claude", "2.1.310", opts(ctx))
      assert :ok = Cache.verify(again)
      assert flush_hits() != []
    end

    test "lookup/3 is read-only: a miss never reaches the network", ctx do
      Fixtures.serve(Fixtures.claude_routes(["2.1.310"]))
      assert :error = Cache.lookup("claude", "2.1.310", opts(ctx))
      assert flush_hits() == []
    end

    test "materialize/2 lays the files out with their modes", ctx do
      Fixtures.serve(Fixtures.codex_routes(["0.164.0"]))
      {:ok, entry} = CliFetcher.ensure("codex", "0.164.0", opts(ctx))
      dest = Path.join(ctx.tmp_dir, "layer")
      assert :ok = Cache.materialize(entry, dest)
      assert File.read!(Path.join(dest, "bin/codex")) == "CODEX-ELF-0.164.0"
      assert File.stat!(Path.join(dest, "bin/codex")).mode |> Bitwise.band(0o111) != 0
    end
  end
end
