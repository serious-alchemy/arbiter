defmodule Arbiter.Worker.Egress.JailRunTest do
  @moduledoc """
  bd-cfktou (G6): what a jailed run's egress is built from: the git remote
  hosts, the Arbiter endpoint bridge, the fixed tunnels, and the lifetime tie
  to the run's owner.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.JailRun

  describe "remote_authority/1" do
    test "reads host:port out of every remote URL form git uses" do
      assert JailRun.remote_authority("git@github.com:org/repo.git") == "github.com:22"
      assert JailRun.remote_authority("ssh://git@example.com/org/repo.git") == "example.com:22"

      assert JailRun.remote_authority("ssh://git@example.com:2222/org/repo.git") ==
               "example.com:2222"

      assert JailRun.remote_authority("https://github.com/org/repo.git") == "github.com:443"

      assert JailRun.remote_authority("https://u:p@git.example.com:8443/r.git") ==
               "git.example.com:8443"

      assert JailRun.remote_authority("http://git.example.com/r.git") == "git.example.com:80"
      assert JailRun.remote_authority("git://git.example.com/r.git") == "git.example.com:9418"
    end

    test "local remotes have no host to allow" do
      assert JailRun.remote_authority("/srv/git/repo.git") == nil
      assert JailRun.remote_authority("../repo") == nil
      assert JailRun.remote_authority("file:///srv/git/repo.git") == nil
    end
  end

  describe "arbiter_bridge/1" do
    test "bridges a loopback endpoint on the same port, so the URLs are unchanged" do
      assert JailRun.arbiter_bridge("http://127.0.0.1:4848/mcp") == {:ok, 4848}
      assert JailRun.arbiter_bridge("http://localhost:4999/mcp") == {:ok, 4999}
    end

    test "a non-loopback endpoint is not bridged: it needs the proxy" do
      assert JailRun.arbiter_bridge("https://arbiter.example.com/mcp") ==
               {:error, :not_loopback}
    end
  end

  describe "start/1" do
    setup do
      dir =
        Path.join(Arbiter.Config.Paths.socket_root(), "jr#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(dir) end)
      owner = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(owner, :kill) end)

      repo = Path.join(dir, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", repo])

      {_, 0} =
        System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:org/r.git"])

      {:ok, dir: dir, owner: owner, repo: repo}
    end

    test "starts the proxy, the Arbiter bridge and the tunnels, and returns the jail's :network",
         %{dir: dir, owner: owner, repo: repo} do
      assert {:ok, network, run_id} =
               JailRun.start(
                 owner: owner,
                 worktree: repo,
                 dir: dir,
                 arbiter_url: "http://127.0.0.1:4848/mcp",
                 tunnels: [{5432, "127.0.0.1", 5432}],
                 infra: ["api.example.com:443"]
               )

      on_exit(fn -> Egress.stop_run(run_id) end)

      assert Egress.running?(run_id)
      assert network[:proxy_socket] == Egress.socket_path(run_id, dir)

      assert network[:bridges] == [
               {4848, Egress.bridge_path(run_id, :arb, dir)},
               {5432, Egress.bridge_path(run_id, :t1, dir)}
             ]

      assert Enum.all?(
               [network[:proxy_socket] | Enum.map(network[:bridges], &elem(&1, 1))],
               &File.exists?/1
             )
    end

    test "the baseline is the adapter's infra hosts plus every git remote's host", %{repo: repo} do
      {_, 0} =
        System.cmd("git", ["-C", repo, "remote", "add", "up", "https://git.example.com/r.git"])

      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "loc", "/srv/git/r.git"])

      assert Enum.sort(JailRun.baseline(repo, ["api.example.com:443"])) ==
               ["api.example.com:443", "git.example.com:443", "github.com:22"]
    end

    test "the run stops with its owner", %{dir: dir, owner: owner, repo: repo} do
      {:ok, network, run_id} =
        JailRun.start(
          owner: owner,
          worktree: repo,
          dir: dir,
          arbiter_url: "http://127.0.0.1:4848/mcp"
        )

      [{sup, _}] = Registry.lookup(Arbiter.Worker.Egress.Registry, {run_id, :sup})
      ref = Process.monitor(sup)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sup, _}, 2_000
      refute File.exists?(network[:proxy_socket])
    end

    test "a start without an owner is refused", %{dir: dir, repo: repo} do
      assert {:error, :no_owner} =
               JailRun.start(worktree: repo, dir: dir, arbiter_url: "http://127.0.0.1:4848/mcp")
    end

    test "events recorded for the run carry the task id", %{dir: dir, owner: owner, repo: repo} do
      {:ok, network, run_id} =
        JailRun.start(
          owner: owner,
          worktree: repo,
          dir: dir,
          task_id: "bd-egress1",
          arbiter_url: "http://127.0.0.1:4848/mcp"
        )

      on_exit(fn -> Egress.stop_run(run_id) end)

      {:ok, sock} =
        :gen_tcp.connect(
          {:local, String.to_charlist(network[:proxy_socket])},
          0,
          [:binary, active: false],
          2_000
        )

      :ok = :gen_tcp.send(sock, "CONNECT catbox.moe:443 HTTP/1.1\r\n\r\n")
      assert {:ok, "HTTP/1.1 403" <> _} = :gen_tcp.recv(sock, 0, 2_000)
      :gen_tcp.close(sock)

      assert [%{task_id: "bd-egress1", host: "catbox.moe", decision: :deny}] =
               Arbiter.Worker.Egress.Event
               |> Ash.Query.filter(run_id == ^run_id)
               |> Ash.read!()
    end

    test "a second start for the same owner reuses the run", %{dir: dir, owner: owner, repo: repo} do
      opts = [owner: owner, worktree: repo, dir: dir, arbiter_url: "http://127.0.0.1:4848/mcp"]
      {:ok, first, run_id} = JailRun.start(opts)
      on_exit(fn -> Egress.stop_run(run_id) end)
      assert {:ok, ^first, ^run_id} = JailRun.start(opts)
    end

    test "a proxy that cannot start is an error, never a missing proxy", %{
      owner: owner,
      repo: repo
    } do
      too_long = Path.join(System.tmp_dir!(), String.duplicate("d", 120))

      assert {:error, :socket_path_too_long} =
               JailRun.start(
                 owner: owner,
                 worktree: repo,
                 dir: too_long,
                 arbiter_url: "http://127.0.0.1:4848/mcp"
               )
    end

    test "an Arbiter endpoint that cannot be bridged is an error", %{
      dir: dir,
      owner: owner,
      repo: repo
    } do
      assert {:error, {:arbiter_endpoint, :not_loopback}} =
               JailRun.start(
                 owner: owner,
                 worktree: repo,
                 dir: dir,
                 arbiter_url: "https://a.example.com/mcp"
               )
    end
  end
end
