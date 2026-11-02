defmodule Arbiter.Worker.Image.SourceTest do
  @moduledoc """
  SI4 (`docs/design/remote-workers.md` §21.2.1, §21.6): the per-run choice of image
  source that replaces `registry_node?/1`'s single read of `caps.image`. A machine
  node pulls the published image only when it lists `registry` in
  `caps.image_sources`, `nodes.machine_image_source` is `auto`, and the repo's
  registry has a pull credential that node may hold; anything else builds from the
  plan, as before. The default is `build`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PullAuth
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.Source

  @install %{
    registry: "install.example.com/arb",
    username: "pusher",
    password: "PUSH-install",
    pull_username: "reader",
    pull_password: "PULL-install"
  }

  defp machine(
         caps \\ %{"image" => "build", "image_sources" => ["registry", "build"]},
         pins \\ []
       ),
       do: %{id: "n1", name: "oryx", kind: :machine, labels: [], workspace_ids: pins, caps: caps}

  defp cluster, do: %{id: "c1", name: "k3s", kind: :cluster, caps: %{"image" => "registry"}}

  defp ctx(workspace \\ %Workspace{id: "ws-1", config: %{}}),
    do: %{workspace: workspace, repo: "vstim"}

  defp opts(extra), do: Keyword.merge([config: @install, workspaces: []], extra)

  test "a cluster (caps.image = registry) takes the registry image, whatever the setting" do
    for source <- ["build", "auto", nil] do
      assert Source.choose(cluster(), ctx(), opts(machine_image_source: source)) == :registry
    end

    assert Source.registry_only?(cluster())
    refute Source.registry_only?(machine())
  end

  test "the default is build: a pull-capable machine with a credential still builds" do
    # nothing set (and no database in this test): `nodes.machine_image_source` reads as build
    assert Source.choose(machine(), ctx(), opts([])) == :build
    assert Source.choose(machine(), ctx(), opts(machine_image_source: "build")) == :build
  end

  test "auto: a machine that lists registry and may hold a credential pulls" do
    assert {:pull, %{auth: %PullAuth{registry: "install.example.com"}, level: :install}} =
             Source.choose(machine(), ctx(), opts(machine_image_source: "auto"))
  end

  test "auto: an agent that does not list registry (an older agent) builds" do
    for caps <- [%{"image" => "build"}, %{}, %{"image_sources" => ["build"]}] do
      assert Source.choose(machine(caps), ctx(), opts(machine_image_source: "auto")) == :build
    end
  end

  test "auto: no pull credential, or one out of the node's reach, builds" do
    no_pull = Map.drop(@install, [:pull_username, :pull_password])

    assert Source.choose(machine(), ctx(), opts(machine_image_source: "auto", config: no_pull)) ==
             :build

    pinned = machine(%{"image_sources" => ["registry", "build"]}, ["ws-1"])
    assert Source.choose(pinned, ctx(), opts(machine_image_source: "auto")) == :build
  end
end
