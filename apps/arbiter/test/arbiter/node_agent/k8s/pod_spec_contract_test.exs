defmodule Arbiter.NodeAgent.K8s.PodSpecContractTest do
  @moduledoc """
  bd-cch1jh: the primary and the cluster controller of one version must agree on the
  mount spec. This runs the primary's own spec builder (`ContainerSpawn.remote_spec/3`,
  as the wire carries it: JSON) for every run kind the placement lane sends, through the
  controller's two gates, `RunSpec.validate/1` and `PodSpec.build/2`.

  A resumed run's `config_dir` mount carries `session` (the transcript its `--resume`
  continues). `RunSpec` parses it into the mount; `PodSpec` once refused it as
  `{:unknown_mount_field, :session}`, so every resume placed on the cluster fell back to
  the primary.
  """
  # async: false — swaps the :output_log_root application env.
  use Arbiter.DataCase, async: false

  import Arbiter.Test.K8sPodFixtures, only: [config: 0, config: 1, put_ref: 1]

  alias Arbiter.NodeAgent.K8s.PodSpec
  alias Arbiter.NodeAgent.PodChannel.BootBundle
  alias Arbiter.NodeAgent.RunSpec
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Workers.Run

  @sid "6f1e0c52-3c7a-4a55-9d0e-6b1c1f6a2b10"

  setup do
    base = Path.join(System.tmp_dir!(), "pod-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    put_app_env(:arbiter, :output_log_root, Path.join(base, "logs"))

    {:ok, ws} = Ash.create(Workspace, %{name: "pc-#{System.unique_integer([:positive])}"})
    {:ok, task} = Ash.create(Issue, %{title: "contract", workspace_id: ws.id})

    proxy = Path.join(base, "proxy.sock")
    File.write!(proxy, "")
    worktree = "/home/arbiter/worktrees/feature-1-#{task.id}"

    request = %{
      name: "arb-t-1",
      provider: "claude",
      image: %{tag: "localhost/x:1", plan: nil},
      worktree: worktree,
      home: "/var/lib/arb/run/home",
      config_dir: Path.join(base, "run/claude-config"),
      config_files: %{"settings.json" => "{}", "CLAUDE.md" => "# memory\n"},
      tmp_dir: Path.join(base, "run"),
      cli: [],
      prompt_paths: [],
      network: [proxy_socket: proxy, socat: "socat"],
      env: [],
      services: [],
      limits: %{},
      checkout: %{home: Path.join(base, "home"), branch: "arbiter/x", base: "main"},
      worktree_files: %{".mcp.json" => "{}"},
      worktree_secrets: %{"ARBITER_MCP_TOKEN" => "scope-token-of-this-run"},
      task_id: task.id
    }

    %{base: base, task: task, request: request}
  end

  defp prior_transcript!(%{base: base, task: task}) do
    config = Path.join(base, "prior-config")
    path = Path.join([config, "projects", "-old-cwd", @sid <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"type" => "user", "message" => "hi"}) <> "\n")

    {:ok, _} =
      Ash.create(Run, %{
        task_id: task.id,
        task_title: "t",
        repo: "r/r",
        state: :finished,
        outcome: :interrupted,
        started_at: DateTime.utc_now(),
        session_id: @sid,
        config_dir: config,
        provider: "claude"
      })
  end

  # What the controller sees: the spec after the wire (JSON), validated, then built.
  defp through_controller(spec) do
    with {:ok, run_spec} <- spec |> Jason.encode!() |> Jason.decode!() |> RunSpec.validate(),
         {:ok, pod} <- PodSpec.build(put_ref(run_spec), config(%{install_id: run_spec.install})) do
      {:ok, run_spec, pod}
    end
  end

  defp args(argv), do: %{argv: argv, env: [{"TMPDIR", "/tmp"}]}

  @fresh ["claude", "--print", "--output-format", "stream-json"]
  @resume ["claude", "--print", "--resume", @sid, "continue"]

  describe "the primary's spec for each run kind is accepted by the controller" do
    test "a fresh run (implement, conflict resolver, fix pass)", ctx do
      {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, args(@fresh), "run-fresh")
      assert {:ok, _run_spec, _pod} = through_controller(spec)
    end

    test "a read-only checkout (a reviewer's clone)", ctx do
      request = put_in(ctx.request, [:checkout, :read_only?], true)
      {:ok, spec} = ContainerSpawn.remote_spec(request, args(@fresh), "run-review")
      assert {:ok, _run_spec, _pod} = through_controller(spec)
    end

    test "a run with no checkout to sync", ctx do
      request = %{ctx.request | checkout: nil}
      {:ok, spec} = ContainerSpawn.remote_spec(request, args(@fresh), "run-nocheckout")
      assert {:ok, _run_spec, _pod} = through_controller(spec)
    end

    test "a session resume: the config_dir mount carries the transcript's session", ctx do
      prior_transcript!(ctx)
      {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, args(@resume), "run-resume")

      config_dir = Enum.find(spec["mounts"], &(&1["kind"] == "config_dir"))
      assert %{"path" => _, "bytes" => _, "sha256" => _} = config_dir["session"]

      assert {:ok, run_spec, _pod} = through_controller(spec)
      assert %{session: %{path: path}} = Enum.find(run_spec.mounts, &(&1.kind == "config_dir"))
      assert path =~ ClaudeSessionFile.project_slug(ctx.request.worktree)
    end

    test "the boot bundle of a resume tells the pod which transcript to fetch", ctx do
      prior_transcript!(ctx)
      {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, args(@resume), "run-resume")
      {:ok, run_spec, _pod} = through_controller(spec)

      bundle = run_spec |> BootBundle.build(%{}) |> untar()
      manifest = Jason.decode!(Map.fetch!(bundle, "manifest.json"))

      %{session: session} = Enum.find(run_spec.mounts, &(&1.kind == "config_dir"))

      assert manifest["session"] == %{
               "path" => session.path,
               "bytes" => session.bytes,
               "sha256" => session.sha256
             }
    end

    test "a run with no session names none in the boot bundle", ctx do
      {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, args(@fresh), "run-fresh")
      {:ok, run_spec, _pod} = through_controller(spec)

      manifest = run_spec |> BootBundle.build(%{}) |> untar() |> Map.fetch!("manifest.json")
      assert Jason.decode!(manifest)["session"] == nil
    end
  end

  describe "PodSpec.build/2 on a parsed config_dir mount" do
    test "accepts :session, and still refuses a field it does not know" do
      mount = %{kind: "config_dir", path: "/var/lib/arb/run/claude-config"}
      session = %{path: "projects/-x/#{@sid}.jsonl", bytes: 3, sha256: String.duplicate("a", 64)}

      assert {:ok, _} = build_with_config_mount(Map.put(mount, :session, session))

      assert {:error, {:bad_spec, {:unknown_mount_field, :surprise}}} =
               build_with_config_mount(Map.put(mount, :surprise, 1))
    end
  end

  defp build_with_config_mount(mount) do
    {:ok, run_spec} = Arbiter.Test.K8sPodFixtures.wire_spec() |> RunSpec.validate()

    mounts =
      Enum.map(run_spec.mounts, fn
        %{kind: "config_dir"} -> mount
        other -> other
      end)

    PodSpec.build(put_ref(%{run_spec | mounts: mounts}), config())
  end

  defp untar(tar) do
    {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
    Map.new(files, fn {name, bytes} -> {to_string(name), bytes} end)
  end
end
