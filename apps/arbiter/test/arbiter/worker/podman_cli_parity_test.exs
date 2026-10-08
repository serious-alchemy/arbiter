defmodule Arbiter.Worker.PodmanCliParityTest do
  @moduledoc """
  bd-4pxt2i: the CLIs a worker expects (what bwrap gets from the host) must
  resolve in the podman spec. `arb`/`claude` come from the REAL spec builder
  (`ContainerSpawn.cli_mounts/2`) and must land in a PATH directory; the
  toolchain (`mix`/`elixir`/`erl`) comes from the image's `beam` layer.
  `gh`/`glab` are deliberately absent (workers use MCP; no forge token is
  mounted), and the worker prompt says so.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Container
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.PromptBuilder

  @mounted ~w(arb claude)
  @in_base_image ~w(git curl bc)
  @deliberately_absent ~w(gh glab)

  defp cli_mounts(extra \\ []) do
    opts =
      [
        find_executable: fn
          "claude" -> "/host/bin/claude"
          "arb" -> "/host/bin/arb"
          _ -> nil
        end
      ] ++ extra

    {:ok, mounts} = ContainerSpawn.cli_mounts("claude", opts)
    mounts
  end

  defp argv(extra) do
    Container.argv(
      Map.merge(
        %{
          podman: "/usr/bin/podman",
          image: "localhost/arbiter-dev/beam-1.19.4-28.2",
          name: "arb-parity",
          worktree: "/work/tree",
          cli_mounts: cli_mounts()
        },
        extra
      ),
      ["claude", "--print"]
    )
  end

  test "the real spec builder mounts every expected CLI under the image's PATH dir" do
    dests =
      Map.new(cli_mounts(), fn {_host, dest} -> {Path.basename(dest), Path.dirname(dest)} end)

    cf = base_containerfile()

    for name <- @mounted do
      assert dests[name] == "/opt/arbiter/cli", "#{name} is not mounted into /opt/arbiter/cli"
    end

    assert cf =~ "ENV PATH=/opt/arbiter/cli:$PATH"
  end

  test "mounted CLIs are bound read-only; an explicit host PATH still gets the dir" do
    argv = argv(%{env: [{"PATH", "/x/bin"}]})
    volumes = for [flag, v] <- Enum.chunk_every(argv, 2, 1, :discard), flag == "-v", do: v
    [path] = for "PATH=" <> p <- argv, do: p

    for name <- @mounted, do: assert("/host/bin/#{name}:/opt/arbiter/cli/#{name}:ro" in volumes)
    assert path == "/opt/arbiter/cli:/x/bin"
  end

  # mix/elixir/erl live in /usr/local/bin of the official elixir image.
  test "the toolchain layer copies mix/elixir/erl into /usr/local, which is on PATH" do
    src = image_source()
    assert src =~ "COPY --from=beam /usr/local/ /usr/local/"
    assert src =~ "elixir:\#{elixir}-otp-\#{otp}-slim AS beam"
    # Debian's default PATH (the image never overrides it) includes /usr/local/bin.
    refute base_containerfile() =~ ~r/ENV PATH=(?!\/opt\/arbiter\/cli:\$PATH)/
  end

  test "git and the build tools are installed in the base image" do
    base = base_containerfile()
    for pkg <- @in_base_image, do: assert(base =~ pkg)
    assert base =~ "openssh-client"
  end

  test "forge CLIs are not installed in the base image and the prompt points at MCP" do
    base = base_containerfile()
    for name <- @deliberately_absent, do: refute(base =~ ~r/\b#{name}\b/)

    prompt = PromptBuilder.prompt_for(%Arbiter.Tasks.Issue{id: "bd-parity", title: "t"})
    assert prompt =~ "deliberately no `gh`/`glab`"
  end

  defp image_source, do: File.read!(Path.join([File.cwd!(), "lib/arbiter/worker/image.ex"]))

  defp base_containerfile do
    [_, cf] = Regex.run(~r/@base_containerfile """\n(.*?)\n  """/s, image_source())
    cf
  end
end
