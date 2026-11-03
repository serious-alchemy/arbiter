defmodule Arbiter.NodeAgent.SeedLayerTest do
  @moduledoc """
  SI5 (`docs/design/remote-workers.md` §21.2.1): a machine node installs the deps its
  run image's seed layer carries, relocated, instead of running a networked seed job;
  a checkout whose `mix.lock` is not the layer's falls back to that job.

  The podman is a stand-in that serves `podman create` / `cp` / `rm` from a seed-layer
  directory laid out as `/opt/arbiter/seed`. The layer is made from a real Mix project
  with a native-style dependency, and the gate is a real offline `mix compile`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.SeedLayer
  alias Arbiter.Test.NifLayerFixture, as: Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @ref "registry.example.com/arbiter/vstim/worker@sha256:" <> String.duplicate("a", 64)

  setup %{tmp_dir: tmp} do
    {:ok, built: Fixture.build_layer(Path.join(tmp, "build"))}
  end

  # Plays podman for one image whose seed layer is `layer`. Every call is reported to the
  # test; a `cp` of the whole layer is reported as `:layer_extracted`, so "extracted once"
  # is observable.
  defp podman(layer, test, overrides \\ %{}) do
    fn _podman, args, _opts ->
      send(test, {:podman, args})

      case Map.get(overrides, hd(args)) do
        nil -> serve(layer, args, test)
        result -> result
      end
    end
  end

  defp serve(_layer, ["create" | _], _test), do: {"abc123\n", 0}
  defp serve(_layer, ["rm" | _], _test), do: {"", 0}

  defp serve(layer, ["cp", from, dest], test) do
    [_name, path] = String.split(from, ":", parts: 2)
    stamp = Path.join(layer, ".complete")

    case path do
      "/opt/arbiter/seed/.complete" ->
        if File.regular?(stamp) do
          File.cp!(stamp, dest)
          {"", 0}
        else
          {"Error: no such path", 125}
        end

      "/opt/arbiter/seed/." ->
        send(test, :layer_extracted)
        File.mkdir_p!(dest)
        {_, 0} = System.cmd("cp", ["-a", layer <> "/.", dest])
        {"", 0}
    end
  end

  defp opts(tmp, layer, extra \\ []) do
    Keyword.merge(
      [
        root: Path.join(tmp, "node/deps-cache"),
        scratch: Path.join(tmp, "node/deps-seed"),
        home: Path.join(tmp, "home"),
        runner: podman(layer, self()),
        podman: "/usr/bin/podman"
      ],
      extra
    )
  end

  describe "install/3" do
    test "installs the layer's deps into the checkout, relocated to where it runs",
         %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)

      assert {:ok, summary} =
               SeedLayer.install(
                 shadow,
                 @ref,
                 opts(tmp, built.layer, retarget_to: "/work/run-1")
               )

      assert summary.method in [:reflink, :copy]
      assert File.regular?(Path.join(shadow, "deps/nifdep/mix.exs"))
      assert File.dir?(Path.join(shadow, "_build/test/lib/nifdep/ebin"))

      # The manifest names where the checkout runs, not the seed's scratch directory
      # and not the host directory the copy was made in.
      manifest = Path.join(shadow, "_build/test/lib/nifdep/.mix/compile.elixir")
      recorded = manifest |> File.read!() |> :erlang.binary_to_term() |> inspect(limit: :infinity)
      assert recorded =~ "/work/run-1/deps/nifdep"
      refute recorded =~ built.src
      refute recorded =~ shadow

      # The probe container is removed whatever happened.
      assert_received {:podman, ["rm" | _]}
    end

    test "extracts a seed layer once, however many runs install it",
         %{tmp_dir: tmp, built: built} do
      first = Fixture.checkout(Path.join(tmp, "shadow-1"), built)
      second = Fixture.checkout(Path.join(tmp, "shadow-2"), built)

      assert {:ok, _} = SeedLayer.install(first, @ref, opts(tmp, built.layer))
      assert_received :layer_extracted

      # A different run image over the same seed layer (a CLI update moves the digest).
      other = "registry.example.com/arbiter/vstim/worker@sha256:" <> String.duplicate("b", 64)
      assert {:ok, _} = SeedLayer.install(second, other, opts(tmp, built.layer))
      refute_received :layer_extracted

      assert File.regular?(Path.join(second, "deps/nifdep/mix.exs"))
    end

    test "a checkout whose lockfile is not the layer's falls back, extracting nothing",
         %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built, lock: "%{\"jason\" => 1}\n")

      assert {:fallback, {:lock_mismatch, checkout, layer_lock}} =
               SeedLayer.install(shadow, @ref, opts(tmp, built.layer))

      assert checkout != layer_lock
      assert layer_lock == built.lock_hash
      refute_received :layer_extracted
      refute File.exists?(Path.join(shadow, "deps"))
      refute File.exists?(Path.join(shadow, "_build"))
    end

    test "an image without a seed layer falls back", %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)
      empty = Path.join(tmp, "empty-layer")
      File.mkdir_p!(empty)

      assert {:fallback, :no_seed_layer} = SeedLayer.install(shadow, @ref, opts(tmp, empty))
    end

    test "a checkout with no lockfile falls back", %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built, lock: nil)
      assert {:fallback, :no_lockfile} = SeedLayer.install(shadow, @ref, opts(tmp, built.layer))
    end

    test "a podman that cannot create falls back", %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)
      runner = podman(built.layer, self(), %{"create" => {"no such image", 125}})

      assert {:fallback, {:create_failed, 125, "no such image"}} =
               SeedLayer.install(shadow, @ref, opts(tmp, built.layer, runner: runner))
    end

    test "a stamp that does not parse is a fallback, never a guess",
         %{tmp_dir: tmp, built: built} do
      File.write!(Path.join(built.layer, ".complete"), "nonsense\n")
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)

      assert {:fallback, :bad_stamp} = SeedLayer.install(shadow, @ref, opts(tmp, built.layer))
    end
  end

  describe "the offline gate with a NIF dependency (agent path)" do
    test "a layer installed by the agent passes the gate without rebuilding the dependency",
         %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)

      assert {:ok, _} = SeedLayer.install(shadow, @ref, opts(tmp, built.layer))

      {out, status} = Fixture.gate(shadow)
      assert status == 0, out
      refute Fixture.rebuilt?(out), out
    end

    test "control: the same layer copied without relocation does rebuild",
         %{tmp_dir: tmp, built: built} do
      shadow = Fixture.checkout(Path.join(tmp, "shadow"), built)

      for dir <- ["deps", "_build"] do
        {_, 0} = System.cmd("cp", ["-a", Path.join(built.layer, dir), Path.join(shadow, dir)])
      end

      {out, _status} = Fixture.gate(shadow)
      assert Fixture.rebuilt?(out), out
    end
  end
end
