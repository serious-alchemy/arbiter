defmodule Arbiter.Worker.PodmanCliParityTest do
  @moduledoc """
  bd-4pxt2i: the CLIs a worker expects (what bwrap gets from the host) must
  resolve in the podman spec. `arb`/`claude` are mounted under
  `/opt/arbiter/cli` and the spec puts that dir on PATH; the toolchain comes
  from the image. `gh`/`glab` are deliberately absent (workers use MCP; no
  forge token is mounted), and the worker prompt says so.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Container
  alias Arbiter.Worker.PromptBuilder

  @mounted ~w(arb claude)
  @in_base_image ~w(git curl bc ssh)
  @deliberately_absent ~w(gh glab)

  defp argv do
    Container.argv(
      %{
        podman: "/usr/bin/podman",
        image: "localhost/arbiter-dev/beam-1.19.4-28.2",
        name: "arb-parity",
        worktree: "/work/tree",
        cli_mounts: for(n <- @mounted, do: {"/host/#{n}", "/opt/arbiter/cli/#{n}"})
      },
      ["claude", "--print"]
    )
  end

  test "every mounted CLI is bound read-only into a directory that is on PATH" do
    argv = argv()

    volumes = for [flag, v] <- Enum.chunk_every(argv, 2, 1, :discard), flag == "-v", do: v
    [path] = for "PATH=" <> p <- argv, do: p
    dirs = String.split(path, ":")

    for name <- @mounted do
      assert "/host/#{name}:/opt/arbiter/cli/#{name}:ro" in volumes
      assert "/opt/arbiter/cli" in dirs
    end
  end

  test "git and the build tools are installed in the base image" do
    base = base_containerfile()
    for pkg <- @in_base_image -- ["ssh"], do: assert(base =~ pkg)
    assert base =~ "openssh-client"
    assert base =~ "ENV PATH=/opt/arbiter/cli:$PATH"
  end

  test "forge CLIs are not installed in the base image and the prompt points at MCP" do
    base = base_containerfile()
    for name <- @deliberately_absent, do: refute(base =~ ~r/\b#{name}\b/)

    prompt = PromptBuilder.prompt_for(%Arbiter.Tasks.Issue{id: "bd-parity", title: "t"})
    assert prompt =~ "deliberately no `gh`/`glab`"
  end

  defp base_containerfile do
    src = File.read!(Path.join([File.cwd!(), "lib/arbiter/worker/image.ex"]))
    [_, cf] = Regex.run(~r/@base_containerfile """\n(.*?)\n  """/s, src)
    cf
  end
end
