defmodule Arbiter.Worker.CliSetTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ArbCli
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.CliSetFixture

  @moduletag :tmp_dir

  defp root(ctx, name \\ "a"), do: Path.join(ctx.tmp_dir, name)

  describe "resolve/1" do
    test "reads the pinned upstream cache, in churn order, with versions and integrity", ctx do
      assert {:ok, set} = ctx |> root() |> CliSetFixture.put() |> CliSet.resolve()

      assert Enum.map(set.clis, & &1.name) == ["codex", "claude", "arb"]
      assert Enum.map(set.clis, & &1.version) == ["0.130.0", "2.1.310", "1.2.3"]
      assert Enum.all?(set.clis, &(&1.integrity == "sha512-fixture"))
      assert set.hash =~ ~r/\A[0-9a-f]{64}\z/
      assert set.set8 == binary_part(set.hash, 0, 8)
      assert CliSet.providers(set) == ["claude", "codex"]
    end

    test "a CLI whose pin is not cached is left out, never looked up on the host", ctx do
      opts = ctx |> root() |> CliSetFixture.put(codex: nil)

      assert {:ok, set} = CliSet.resolve(opts)
      assert Enum.map(set.clis, & &1.name) == ["claude", "arb"]
      assert CliSet.providers(set) == ["claude"]
    end

    test "a pin that is not in the cache is a miss, not a download", ctx do
      opts = ctx |> root() |> CliSetFixture.put()
      opts = Keyword.put(opts, :cli_pins, %{"claude" => "9.9.9", "codex" => "0.130.0"})

      assert {:ok, set} = CliSet.resolve(opts)
      assert Enum.map(set.clis, & &1.name) == ["codex", "arb"]
    end

    test "the hash is the content: same bytes, same hash, in two caches", ctx do
      a = ctx |> root("a") |> CliSetFixture.put()
      b = ctx |> root("b") |> CliSetFixture.put()

      assert {:ok, one} = CliSet.resolve(a)
      assert {:ok, two} = CliSet.resolve(b)
      assert one.hash == two.hash
      assert one.set8 == two.set8
    end

    test "a version bump with the same bytes does not move the hash; changed bytes do", ctx do
      same_bytes = %{"claude" => "claude-bytes"}

      {:ok, base} =
        ctx |> root("a") |> CliSetFixture.put(content: same_bytes) |> CliSet.resolve()

      {:ok, bumped} =
        ctx
        |> root("b")
        |> CliSetFixture.put(content: same_bytes, claude: "2.1.311")
        |> CliSet.resolve()

      assert Enum.find(bumped.clis, &(&1.name == "claude")).version == "2.1.311"
      assert bumped.hash == base.hash

      {:ok, other} =
        ctx
        |> root("c")
        |> CliSetFixture.put(content: %{"claude" => "a different claude"})
        |> CliSet.resolve()

      refute other.hash == base.hash
    end
  end

  describe "materialize/2 and mounts/2" do
    test "writes the manifest and one directory per CLI under the cli-sets root", ctx do
      set = CliSetFixture.set!(root(ctx))
      assert {:ok, set} = CliSet.materialize(set)

      dir = Path.join(Path.join(root(ctx), "cli-sets"), set.set8)
      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

      assert manifest["set"] == set.hash
      assert manifest["providers"] == ["claude", "codex"]
      assert [%{"name" => "codex"}, %{"name" => "claude"}, %{"name" => "arb"}] = manifest["clis"]

      claude = Enum.find(manifest["clis"], &(&1["name"] == "claude"))
      assert claude["version"] == "2.1.310"
      assert claude["integrity"] == "sha512-fixture"
      assert [%{"path" => "claude", "sha256" => _, "mode" => 0o755}] = claude["files"]

      assert File.read!(Path.join([dir, "claude", "claude"])) == "claude-binary-2.1.310"
      assert Bitwise.band(File.stat!(Path.join([dir, "claude", "claude"])).mode, 0o111) != 0
    end

    test "a provider's mounts are its CLI plus arb, in the container layout", ctx do
      set = CliSetFixture.set!(root(ctx))
      {:ok, set} = CliSet.materialize(set)

      assert {:ok, claude} = CliSet.mounts(set, "claude")

      assert Enum.map(claude, &elem(&1, 1)) ==
               ["/opt/arbiter/cli/claude", "/opt/arbiter/cli/arb", "/opt/arbiter/cli/arb.escript"]

      assert {:ok, codex} = CliSet.mounts(set, "codex")

      assert Enum.map(codex, &elem(&1, 1)) |> Enum.sort() ==
               Enum.sort([
                 "/opt/arbiter/cli/codex",
                 "/opt/arbiter/cli/codex-code-mode-host",
                 "/opt/arbiter/cli/rg",
                 "/opt/arbiter/cli/bwrap",
                 "/opt/arbiter/cli/arb",
                 "/opt/arbiter/cli/arb.escript"
               ])

      for {host, _dest} <- codex ++ claude do
        assert String.starts_with?(host, Path.join(root(ctx), "cli-sets"))
      end

      {host, _} = Enum.find(claude, fn {_, d} -> d == "/opt/arbiter/cli/arb" end)
      assert File.read!(host) == ArbCli.launcher()
    end

    test "a provider the set does not carry is an error naming the CLI", ctx do
      {:ok, set} = ctx |> root() |> CliSetFixture.put(codex: nil) |> CliSet.resolve()
      {:ok, set} = CliSet.materialize(set)

      assert {:error, {:cli_not_cached, "codex"}} = CliSet.mounts(set, "codex")
    end

    test "identical pinned files materialize to byte-identical files with the same modes", ctx do
      {:ok, one} = ctx |> root("a") |> CliSetFixture.set!() |> CliSet.materialize()
      {:ok, two} = ctx |> root("b") |> CliSetFixture.set!() |> CliSet.materialize()

      assert one.hash == two.hash

      for {a, b} <- Enum.zip(file_paths(one), file_paths(two)) do
        assert File.read!(a) == File.read!(b)
        assert File.stat!(a).mode == File.stat!(b).mode
      end
    end

    test "re-materializing repairs a file that was altered on disk", ctx do
      {:ok, set} = ctx |> root() |> CliSetFixture.set!() |> CliSet.materialize()
      [path | _] = file_paths(set)
      File.chmod!(path, 0o644)
      File.write!(path, "tampered")

      assert {:ok, _} = CliSet.materialize(set, verify: true)
      refute File.read!(path) == "tampered"
    end
  end

  describe "labels/1" do
    test "the set, its providers and each CLI's version and integrity", ctx do
      set = CliSetFixture.set!(root(ctx))
      labels = Map.new(CliSet.labels(set))

      assert labels["arbiter.cli-set"] == set.set8
      assert labels["arbiter.cli-providers"] == "claude,codex"
      assert labels["arbiter.cli.claude.version"] == "2.1.310"
      assert labels["arbiter.cli.claude.integrity"] == "sha512-fixture"
      assert labels["arbiter.cli.codex.version"] == "0.130.0"
      assert labels["arbiter.cli.arb.version"] == "1.2.3"
      assert labels["arbiter.cli.claude.sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  describe "no host installs" do
    @resolvers ~w(
      lib/arbiter/worker/cli_set.ex
      lib/arbiter/worker/container_spawn.ex
      lib/arbiter/worker/image/publisher.ex
      lib/arbiter/worker/image/publisher/pipeline.ex
    )

    test "the resolver, the spawn and the publisher never look a CLI up on the host" do
      for file <- @resolvers do
        source = File.read!(file)

        for needle <- ["find_executable", "host_escript", "installed_arb", ".local/bin"] do
          refute source =~ needle, "#{file} mentions #{needle}"
        end
      end
    end
  end

  defp file_paths(set) do
    for cli <- set.clis, f <- cli.files, do: f.path
  end
end
