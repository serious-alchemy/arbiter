defmodule Arbiter.NodeAgent.K8s.PodSeedLayerTest do
  @moduledoc """
  SI5 (`docs/design/remote-workers.md` §21.2.1): the pod's `seed` init container installs
  the image's seed layer *relocated*. `/opt/arbiter/bin/seed-layer` is what `seed` calls;
  the test lays the image's `/opt/arbiter/bin` out the way the base Containerfile does
  (`PodScripts.bin/0` and `PodScripts.sources/0`) and runs the script under the image's
  shell with the real `elixir`, then runs the offline gate in the result.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H
  alias Arbiter.Test.NifLayerFixture, as: Fixture

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "opt-arbiter-bin")
    File.mkdir_p!(bin)

    for {name, text} <- Map.merge(PodScripts.bin(), PodScripts.sources()) do
      File.write!(Path.join(bin, name), text)
      File.chmod!(Path.join(bin, name), 0o755)
    end

    {:ok, bin: bin, built: Fixture.build_layer(Path.join(tmp, "build"))}
  end

  # What the init container does: the layer is a read-only directory, the checkout a
  # volume, and `runs_at` is where the worker container mounts that volume.
  defp seed_layer(bin, built, wt, runs_at, env \\ []) do
    File.mkdir_p!(wt)

    System.cmd(H.shell(), [Path.join(bin, "seed-layer"), built.layer, wt, runs_at],
      env: [{"ARB_BIN_DIR", bin}, {"LANG", "C.UTF-8"}] ++ env,
      stderr_to_stdout: true
    )
  end

  test "the image carries the script and the two source files it relocates with" do
    assert Map.has_key?(PodScripts.bin(), "seed-layer")

    assert Enum.sort(Map.keys(PodScripts.sources())) == [
             "deps_relocate.ex",
             "deps_relocate_etf.ex"
           ]

    # The same text as the files the agent runs: there is one relocation, two runtimes.
    lib = Path.expand("../../../../lib/arbiter/worker", __DIR__)

    assert PodScripts.sources()["deps_relocate.ex"] ==
             File.read!(Path.join(lib, "deps_relocate.ex"))

    assert PodScripts.sources()["deps_relocate_etf.ex"] ==
             File.read!(Path.join(lib, "deps_relocate/etf.ex"))
  end

  test "`seed` installs the layer through seed-layer, handing it where the worker runs" do
    seed = PodScripts.bin()["seed"]
    assert seed =~ ~s("$seed_layer" "$wt" "${ARB_WORKTREE:-$wt}")
    assert seed =~ "seed-layer"
  end

  test "a layer installed by the pod passes the offline gate without rebuilding",
       %{tmp_dir: tmp, bin: bin, built: built} do
    # The checkout the init container builds (committed files) and the layer's contents
    # on top, at the path the worker will mount it.
    wt = Fixture.checkout(Path.join(tmp, "work/wt"), built)

    assert {_, 0} = seed_layer(bin, built, wt, wt)

    assert File.regular?(Path.join(wt, "deps/nifdep/priv/nif.so"))
    refute File.exists?(Path.join(wt, ".complete")), "the stamp is not part of the checkout"
    refute File.exists?(Path.join(wt, "mix_home")), "Hex and rebar stay with the image"

    {out, status} = Fixture.gate(wt)
    assert status == 0, out
    refute Fixture.rebuilt?(out), out
  end

  test "control: the layer copied without the relocation does rebuild",
       %{tmp_dir: tmp, built: built} do
    wt = Fixture.checkout(Path.join(tmp, "work/wt"), built)

    for dir <- ["deps", "_build"] do
      {_, 0} = System.cmd("cp", ["-a", Path.join(built.layer, dir), Path.join(wt, dir)])
    end

    {out, _status} = Fixture.gate(wt)
    assert Fixture.rebuilt?(out), out
  end

  test "the manifests name where the worker runs, which is not where the init container copies",
       %{tmp_dir: tmp, bin: bin, built: built} do
    wt = Fixture.checkout(Path.join(tmp, "work/wt"), built)

    assert {_, 0} = seed_layer(bin, built, wt, "/work/run-9")

    manifest = Path.join(wt, "_build/test/lib/nifdep/.mix/compile.elixir")
    recorded = manifest |> File.read!() |> :erlang.binary_to_term() |> inspect(limit: :infinity)
    assert recorded =~ "/work/run-9/deps/nifdep"
    refute recorded =~ built.src
    refute recorded =~ wt
  end

  test "a layer with no stamp still installs, and says the dependencies will rebuild",
       %{tmp_dir: tmp, bin: bin, built: built} do
    File.rm!(Path.join(built.layer, ".complete"))
    wt = Fixture.checkout(Path.join(tmp, "work/wt"), built)

    assert {out, 0} = seed_layer(bin, built, wt, wt)
    assert out =~ "no .complete stamp"
    assert File.regular?(Path.join(wt, "deps/nifdep/priv/nif.so"))
  end

  test "an image without elixir installs the layer and says the dependencies will rebuild",
       %{tmp_dir: tmp, bin: bin, built: built} do
    wt = Fixture.checkout(Path.join(tmp, "work/wt"), built)

    # A PATH holding only what the script itself needs: no elixir, wherever this host
    # keeps it.
    tools = Path.join(tmp, "tools")
    File.mkdir_p!(tools)

    for tool <- ~w(cp sed head chmod dirname) do
      File.ln_s!(System.find_executable(tool), Path.join(tools, tool))
    end

    assert {out, 0} = seed_layer(bin, built, wt, wt, [{"PATH", tools}])
    assert out =~ "no elixir"
    assert File.regular?(Path.join(wt, "deps/nifdep/priv/nif.so"))
  end
end
