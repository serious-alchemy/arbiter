defmodule Arbiter.NodeAgent.PodRuntimeHarness do
  @moduledoc false
  # The pod's shell scripts (`priv/k8s_pod/seed`, `snapshotter`, the entry
  # wrapper) against the controller's real `:9444` listener
  # (`Arbiter.NodeAgent.PodChannel.PodServer`) and a stand-in primary that serves
  # a real git bundle and records what the controller forwards. Used by the
  # local-`sh` harness and the opt-in podman one.

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.PodChannel.{Cert, PodServer, Runs}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit

  @loopback {127, 0, 0, 1}
  @credential "arbn_harness_credential"
  @run "run-1"

  def run_id, do: @run

  defmodule Primary do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(%{method: "GET", path_info: ["nodes", "runs", run, "seed.bundle"]} = conn, opts) do
      send(Keyword.fetch!(opts, :test), {:primary, :seed, run})
      conn |> send_file(200, Keyword.fetch!(opts, :bundle))
    end

    def call(%{method: "PUT", path_info: ["nodes", "runs", run, kind]} = conn, opts) do
      {:ok, body, conn} = read_all(conn, "")
      send(Keyword.fetch!(opts, :test), {:primary, kind, run, body})
      send_resp(conn, 200, ~s({"ingested":#{byte_size(body)}}))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, data, conn} -> {:ok, acc <> data, conn}
        {:more, data, conn} -> read_all(conn, acc <> data)
      end
    end
  end

  @doc "Run `git` in `dir` with a fixed identity; the output."
  def git!(dir, args, env \\ []) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"} | env]
      )

    out
  end

  @doc """
  A fixture repo with `main` (one commit) and `feature/x` (one more) and the
  seed bundle the primary would serve for it. `%{repo, bundle, head, base}`.
  """
  def fixture!(dir) do
    repo = Path.join(dir, "fixture")
    File.mkdir_p!(Path.join(repo, "lib"))
    git!(repo, ["init", "-q", "-b", "main"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    File.write!(Path.join(repo, "lib/a.ex"), "defmodule A do\nend\n")
    File.write!(Path.join(repo, "run.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(repo, "run.sh"), 0o755)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    git!(repo, ["checkout", "-q", "-b", "feature/x"])
    File.write!(Path.join(repo, "lib/b.ex"), "defmodule B do\nend\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "feature"])

    bundle = Path.join(dir, "seed.bundle")
    git!(repo, ["bundle", "create", bundle, "refs/heads/feature/x", "refs/heads/main"])

    %{
      repo: repo,
      bundle: bundle,
      head: String.trim(git!(repo, ["rev-parse", "refs/heads/feature/x"])),
      base: String.trim(git!(repo, ["rev-parse", "refs/heads/main"]))
    }
  end

  @doc """
  Start the controller side: CA, run table, stand-in primary, the `:9444`
  listener. Returns the paths and ports the scripts need, plus `nonce` for a
  freshly registered run with `spec_overrides`.
  """
  def start!(dir, fixture, spec_overrides \\ %{}) do
    ca = Kit.ca()
    runs = start_supervised!({Runs, ca: ca, name: nil}, id: :harness_runs)

    primary =
      start_supervised!(
        {Bandit,
         plug: {Primary, test: self(), bundle: fixture.bundle},
         scheme: :http,
         ip: @loopback,
         port: 0},
        id: :harness_primary
      )

    {:ok, {_, primary_port}} = ThousandIsland.listener_info(primary)

    config = %Config{
      primary_url: "http://127.0.0.1:#{primary_port}",
      credential: @credential,
      req_options: []
    }

    server =
      start_supervised!(
        {PodServer,
         identity: Kit.server_identity(ca),
         ca: ca,
         runs: runs,
         config: config,
         ip: @loopback,
         port: 0,
         notify: self(),
         max_upload_bytes: 50_000_000},
        id: :harness_server
      )

    ca_file = Path.join(dir, "ca.crt")
    File.write!(ca_file, Cert.pem_cert(ca.der))

    spec = Kit.spec!(@run, ["proxy", "arb"], spec_overrides)
    {:ok, nonce} = Runs.register(runs, spec, DateTime.add(DateTime.utc_now(), 600))
    :ok = Runs.bind_pod_ip(runs, @run, @loopback)

    %{
      runs: runs,
      ca_file: ca_file,
      port: PodServer.port(server),
      nonce: nonce
    }
  end

  @doc """
  The shell the scripts run under: `dash` when the host has it, as the image's
  `/bin/sh` is (Debian), else `sh`. A bashism fails here rather than in a pod.
  """
  def shell, do: System.find_executable("dash") || System.find_executable("sh")

  @doc "The path of a script under `priv/k8s_pod`."
  def script(name), do: Path.join(Application.app_dir(:arbiter, "priv/k8s_pod"), name)
end
