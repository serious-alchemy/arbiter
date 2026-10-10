defmodule Arbiter.Test.K8sPodFixtures do
  @moduledoc """
  Shared inputs for the `Arbiter.NodeAgent.K8s` conformance tests (K4): a run
  spec as the primary would send it, the controller config the builder reads,
  and the golden-file helper.
  """

  alias Arbiter.NodeAgent.K8s.PodSpec
  alias Arbiter.NodeAgent.RunSpec

  @digest String.duplicate("ab", 32)
  @registry "registry.example.test/arbiter"

  def registry, do: @registry
  def digest, do: @digest

  @doc "The wire form of a run (string keys) the way `assign` carries it."
  def wire_spec(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run" => "run-0123456789abcdef",
        "task" => "bd-1nfuq5",
        "name" => "arb-run-0123456789ab",
        "install" => "inst-1",
        "image" => %{"tag" => "arbiter-dev/beam:abc123", "plan" => nil},
        "cwd" => "/home/arbiter/worktrees/bd-1nfuq5",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/home/arbiter/worktrees/bd-1nfuq5"},
          %{"kind" => "home", "path" => "/var/lib/arb/run/home"},
          %{"kind" => "config_dir", "path" => "/var/lib/arb/run/claude-config"},
          %{"kind" => "tmp", "path" => "/tmp"},
          %{
            "kind" => "cli",
            "name" => "claude",
            "sha256" => String.duplicate("a", 64),
            "path" => "/opt/arbiter/cli/claude"
          },
          %{
            "kind" => "prompt",
            "path" => "/var/lib/arb/run/prompt.md",
            "content" => Base.encode64("do the thing")
          }
        ],
        "bridges" => [],
        "env" => %{"ARB_WORKER_BEAD_ID" => "bd-1nfuq5", "LANG" => "C.UTF-8"},
        "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat-SECRET-VALUE"},
        "limits" => %{"memory" => "3g", "memory_swap" => "3g", "cpus" => "1.5"},
        "command" => ["claude", "--print", "--output-format", "stream-json"]
      },
      overrides
    )
  end

  def run_spec(overrides \\ %{}) do
    {:ok, spec} = RunSpec.validate(wire_spec(overrides))
    put_ref(spec)
  end

  @doc "`RunSpec` has no `ref` yet (design A2); the controller adds the digest-pinned reference."
  def put_ref(%RunSpec{image: image} = spec, ref \\ nil) do
    %{spec | image: Map.put(image, :ref, ref || "#{@registry}/beam@sha256:#{@digest}")}
  end

  def with_bridges(overrides \\ %{}) do
    wire_spec(
      Map.merge(
        %{
          "bridges" => [
            %{"name" => "proxy", "path" => "/var/lib/arb/run/sockets/proxy.sock"},
            %{"name" => "arb", "path" => "/var/lib/arb/run/sockets/arb.sock"}
          ]
        },
        overrides
      )
    )
  end

  def config(overrides \\ %{}) do
    Map.merge(
      %{
        registry: @registry,
        install_id: "inst-1",
        node_id: "node-1",
        owner_uid: "0b6c1d7e-8f35-4a58-9c1f-3d2f1b1c1a11",
        bridge_addr: "10.43.98.199",
        gate_addr: "10.43.0.1:443",
        boot_nonce: String.duplicate("n", 43),
        max_wall_s: 3600
      },
      overrides
    )
  end

  def build!(spec \\ nil, config \\ %{}) do
    {:ok, pod} = PodSpec.build(spec || run_spec(), config(config))
    pod
  end

  # -- pod navigation ------------------------------------------------------------------

  def containers(pod), do: pod["spec"]["initContainers"] ++ pod["spec"]["containers"]
  def container(pod, name), do: Enum.find(containers(pod), &(&1["name"] == name))
  def worker(pod), do: container(pod, "worker")

  # -- golden files --------------------------------------------------------------------

  @doc """
  Compares `pod` (as YAML) with `test/fixtures/k8s/<name>.yaml`. Set
  `ARB_UPDATE_GOLDEN=1` to rewrite the file after a deliberate change; the diff
  is then the review.
  """
  def golden_yaml(pod), do: Ymlr.document!(pod)

  def golden_path(name),
    do: Path.join([__DIR__, "..", "fixtures", "k8s", name <> ".yaml"]) |> Path.expand()
end
