defmodule Arbiter.Worker.DepsCachePodmanTest do
  @moduledoc """
  bd-1wm14e (P6): `Arbiter.Worker.DepsCache` against a REAL rootless podman.

  Opt-in (`@moduletag :podman`): it seeds a one-dependency Mix project inside a
  local worker image (needs network for Hex) and then compiles from the copy in
  a container with `--network=none`:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/deps_cache_podman_test.exs

  The image is the first local `localhost/arbiter-dev/beam-*` one (`arb image
  build` makes it), or `ARBITER_TEST_BEAM_IMAGE`. Containers are `arb-test-…`
  and removed by that exact name.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.DepsCache

  @moduletag :podman
  @moduletag timeout: 600_000

  @mix_exs """
  defmodule Tiny.MixProject do
    use Mix.Project
    def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.15", deps: [{:decimal, "2.3.0"}]]
    def application, do: []
  end
  """

  @mix_lock ~S"""
  %{
    "decimal": {:hex, :decimal, "2.3.0", "3ad6255aa77b4a3c4f818171b12d237500e63525c2fd056699967a3e7ea20f62", [:mix], [], "hexpm", "a4d66355cb29cb47c3cf30e71329e58361cfcb37c34235ef3bf1d7bf3773aeac"},
  }
  """

  setup do
    image = image!()
    parent = Path.join(System.tmp_dir!(), "dcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(parent)
    on_exit(fn -> File.rm_rf(parent) end)

    ctx =
      GitFixture.forge_and_checkout(%{"mix.exs" => @mix_exs, "mix.lock" => @mix_lock},
        parent: parent
      )

    opts = [root: Path.join(ctx.root, "cache"), scratch: Path.join(ctx.root, "scratch")]
    Map.merge(ctx, %{image: image, opts: opts})
  end

  defp image! do
    case System.get_env("ARBITER_TEST_BEAM_IMAGE") do
      tag when is_binary(tag) and tag != "" ->
        tag

      _ ->
        {out, 0} = System.cmd("podman", ["images", "--format", "{{.Repository}}:{{.Tag}}"])

        out
        |> String.split("\n", trim: true)
        |> Enum.find(&String.starts_with?(&1, "localhost/arbiter-dev/beam-")) ||
          flunk("no local localhost/arbiter-dev/beam-* image; run `arb image build`")
    end
  end

  test "seeds in the image, and a worker copy compiles offline with no Hex install", ctx do
    assert {:ok, %{seeded?: true, dir: cache}} =
             DepsCache.ensure(ctx.checkout, "main", ctx.image, ctx.opts)

    assert [_ | _] = Path.wildcard(Path.join(cache, "_build/test/lib/decimal/ebin/*.beam"))
    assert [_ | _] = Path.wildcard(Path.join(cache, "mix_home/archives/hex-*"))

    worker = Path.join(ctx.root, "worker")
    home = Path.join(ctx.root, "home")
    File.mkdir_p!(Path.join(worker, ".git"))
    File.mkdir_p!(home)
    GitFixture.git!(ctx.checkout, ["archive", "-o", Path.join(ctx.root, "t.tar"), "origin/main"])
    {_, 0} = System.cmd("tar", ["-xf", Path.join(ctx.root, "t.tar"), "-C", worker])

    assert {:ok, %{method: method}} = DepsCache.install(cache, worker, ctx.opts)
    assert method in [:reflink, :copy]
    assert {:ok, home_method} = DepsCache.install_mix_home(cache, home, ctx.opts)
    assert home_method in [:reflink, :copy]

    name = Container.name_for("test-deps-#{System.unique_integer([:positive])}")
    on_exit(fn -> Container.stop(name) end)

    script = ~S"""
    mix deps.compile 2>&1; echo "rc=$?"
    mix run -e 'IO.puts("sum=" <> Decimal.to_string(Decimal.add(Decimal.new(1), 2)))' 2>&1
    """

    assert {:ok, {out, 0}} =
             Container.run(["sh", "-c", script],
               worktree: worker,
               home: home,
               image: ctx.image,
               name: name,
               network: :none,
               env: [{"MIX_ENV", "test"}, {"LANG", "C.UTF-8"}]
             )

    # Nothing is rebuilt (Mix would say "Compiling" if the manifest still named
    # the seed's directory), nothing asks to install Hex, and the dep loads.
    refute out =~ "Compiling"
    refute out =~ "Shall I install Hex"
    assert out =~ "rc=0"
    assert out =~ "sum=3"
  end

  test "a different image misses the cache and seeds its own", ctx do
    assert {:ok, %{dir: a}} = DepsCache.ensure(ctx.checkout, "main", ctx.image, ctx.opts)

    # Same toolchain, different tag: the key must not collide, whatever is inside.
    other = "localhost/arbiter-dev/other:cafecafecafe"
    assert {:ok, key} = DepsCache.key(ctx.checkout, "main", other, ctx.opts)
    assert key.dir != a
    refute File.exists?(key.dir)
  end
end
