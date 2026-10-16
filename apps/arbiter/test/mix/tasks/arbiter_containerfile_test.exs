defmodule Mix.Tasks.Arbiter.ContainerfileTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Publisher.Pipeline
  alias Mix.Tasks.Arbiter.Containerfile

  @digest "sha256:" <> String.duplicate("a", 64)
  defp resolver, do: fn _ref -> {:ok, @digest} end

  setup do
    dir = Path.join(System.tmp_dir!(), "containerfile-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "render/3" do
    test "controller is the Containerfile the primary publishes, unpinned by default" do
      assert {:ok, text, %{hash: nil}} = Containerfile.render("controller", [], resolver())
      assert text == Pipeline.controller_containerfile()
    end

    test "controller --pin digest-pins its FROM through Image.pin/2" do
      assert {:ok, text, _} = Containerfile.render("controller", [pin: true], resolver())
      assert {:ok, pinned, _pins} = Image.pin(Pipeline.controller_containerfile(), resolver())
      assert text == pinned
      assert text =~ "debian:trixie-slim@#{@digest}"
    end

    test "worker-base is Image.base_containerfile/1 and its hash is the primary's base tag hash" do
      assert {:ok, text, %{hash: hash}} =
               Containerfile.render("worker-base", [pin: true, arb_otp: "29"], resolver())

      assert {:ok, base} = Image.base_layer(resolver(), "29")
      assert text == base.containerfile
      assert hash == base.hash
      assert text =~ "erlang:29-slim@#{@digest}"
    end

    test "an unpinned worker-base has no hash (the hash covers the pinned text)" do
      assert {:ok, _text, %{hash: nil}} =
               Containerfile.render("worker-base", [arb_otp: "29"], resolver())
    end

    test "an unresolvable FROM is an error naming the ref" do
      resolver = fn _ -> {:error, "no network"} end

      assert {:error, {:unpinned_base, "docker.io/library/debian:trixie-slim", _}} =
               Containerfile.render("controller", [pin: true], resolver)
    end

    test "an unknown kind is refused" do
      assert {:error, {:unknown_kind, "nope"}} = Containerfile.render("nope", [], resolver())
    end
  end

  describe "run/1" do
    test "writes the Containerfile and the hash to the named files", %{dir: dir} do
      out = Path.join(dir, "Containerfile.worker-base")
      hash_out = Path.join(dir, "hash")

      Containerfile.write!(
        "worker-base",
        [out: out, hash_out: hash_out, pin: true, arb_otp: "29"],
        resolver()
      )

      {:ok, base} = Image.base_layer(resolver(), "29")
      assert File.read!(out) == base.containerfile
      assert File.read!(hash_out) == base.hash <> "\n"
    end

    test "--hash-out is refused for the controller", %{dir: dir} do
      assert_raise Mix.Error, ~r/hash/, fn ->
        Containerfile.write!("controller", [hash_out: Path.join(dir, "h"), pin: true], resolver())
      end
    end
  end

  describe "release workflow" do
    @workflow File.read!("../../.github/workflows/release.yml")

    test "renders both Containerfiles with this task, digest-pinned" do
      assert @workflow =~ "mix arbiter.containerfile controller --pin"
      assert @workflow =~ "mix arbiter.containerfile worker-base --pin"
      assert @workflow =~ "--hash-out"
    end

    test "publishes controller, worker base and chart to GHCR" do
      assert @workflow =~ "publish-oci:"
      assert @workflow =~ "packages: write"
      assert @workflow =~ "arbiter-controller"
      assert @workflow =~ "arbiter-worker-base"
      assert @workflow =~ "helm push"
    end

    test "cosign is only ever run behind the SIGN flag" do
      {:ok, workflow} = YamlElixir.read_from_string(@workflow)

      signing =
        for {_job, %{"steps" => steps}} <- workflow["jobs"],
            step <- steps,
            String.contains?("#{step["run"]} #{step["uses"]}", ["cosign sign", "cosign-installer"]),
            do: step

      assert length(signing) == 2
      assert Enum.all?(signing, &(&1["if"] == "env.SIGN == 'true'"))
    end
  end
end
