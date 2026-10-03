defmodule Arbiter.Worker.TestServicesPodmanTest do
  @moduledoc """
  bd-dmcbos (P10): `Arbiter.Worker.TestServices` against a REAL rootless
  podman. A worker container joins a per-worker pod whose `lo` also holds a
  Postgres sidecar, runs SQL against it, and cannot reach a listener on the
  host's loopback.

  Opt-in (`@moduletag :podman`): it starts pods and needs a ready podman, the
  local images below and no network:

      podman pull docker.io/library/postgres:16-alpine
      podman pull docker.io/library/postgres:15-alpine   # tonic's pod
      podman pull docker.io/pgsty/silo                   # tonic's S3 store
      cd apps/arbiter && mix test --include podman test/arbiter/worker/test_services_podman_test.exs

  The worker image is the Postgres one only because it carries `psql` and
  `nc`; the point is the pod, not the image. Every pod and container is named
  `arb-test-…` and removed by that exact name: never a pattern kill (this repo's
  coordinator runs on the same host).
  """
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Container
  alias Arbiter.Worker.TestServices
  alias Arbiter.Worker.TestServices.Reaper

  @moduletag :podman
  @moduletag timeout: 240_000
  @image "docker.io/library/postgres:16-alpine"

  setup do
    {_, 0} = System.cmd("podman", ["image", "exists", @image])
    dir = Path.join(System.tmp_dir!(), "arb-p10-t-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = Container.name_for("test-p10-#{System.unique_integer([:positive])}")
    pod = TestServices.pod_name(name)

    on_exit(fn ->
      TestServices.stop(pod)
      File.rm_rf!(dir)
    end)

    {:ok, services} = TestServices.for_repo("vstim")
    %{dir: dir, name: name, pod: pod, services: services}
  end

  defp start(ctx, extra \\ []) do
    TestServices.start(
      Keyword.merge(
        [name: ctx.name, services: ctx.services, pull: false, ready_timeout_ms: 120_000],
        extra
      )
    )
  end

  defp pod_exists?(pod), do: match?({_, 0}, System.cmd("podman", ["pod", "exists", pod]))

  defp container_exists?(name),
    do: match?({_, 0}, System.cmd("podman", ["container", "exists", name]))

  defp await(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          100 -> await(fun, tries - 1)
        end
    end
  end

  # A host listener the container must not be able to reach.
  defp host_loopback_listener do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    port
  end

  test "a worker container runs SQL against the pod's Postgres and sees no host loopback",
       ctx do
    port = host_loopback_listener()

    # Control: the listener really is reachable from the host.
    assert {:ok, probe} = :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 2_000)
    :gen_tcp.close(probe)

    assert {:ok, %{pod: pod, env: env}} = start(ctx)
    assert pod == ctx.pod

    # The stand-in for a repo's suite: DDL, writes and a read through the
    # DATABASE_URL the pod handed the worker. (vstim's own `mix test` needs its
    # deps from the network, which this container does not have.)
    script = ~S"""
    set -e
    echo "ifaces=$(cut -d: -f1 /proc/net/dev | tail -n +3 | tr -d ' ' | tr '\n' ,)"
    echo "uid=$(id -u)"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q \
      -c "create table suite(i int)" -c "insert into suite values (1),(2),(3)"
    echo "sum=$(psql "$DATABASE_URL" -tA -c 'select sum(i) from suite')"
    echo "db=$(psql "$DATABASE_URL" -tA -c 'select current_database()')"
    if nc -z -w1 127.0.0.1 "$HOST_PORT"; then echo HOST_LOOPBACK=reachable; else echo HOST_LOOPBACK=unreachable; fi
    """

    {host_uid, 0} = System.cmd("id", ["-u"])

    assert {:ok, {out, 0}} =
             Container.run(
               ["sh", "-c", script],
               worktree: ctx.dir,
               name: ctx.name,
               image: @image,
               pod: pod,
               env: [{"HOST_PORT", Integer.to_string(port)} | env]
             )

    assert out =~ "ifaces=lo,"
    assert out =~ "uid=#{String.trim(host_uid)}"
    assert out =~ "sum=6"
    assert out =~ "db=vstim_test"
    assert out =~ "HOST_LOOPBACK=unreachable"
    refute out =~ "HOST_LOOPBACK=reachable"

    # The worker container is gone (--rm); the pod and its sidecar are not, until stopped.
    refute container_exists?(ctx.name)
    assert pod_exists?(pod)
    assert container_exists?(TestServices.service_name(ctx.name, hd(ctx.services)))

    assert :ok = TestServices.stop(pod)
    refute pod_exists?(pod)
    refute container_exists?(TestServices.service_name(ctx.name, hd(ctx.services)))
  end

  test "tonic's pod holds Postgres 15 and an S3 store, both on the worker's loopback", ctx do
    {:ok, services} = TestServices.for_repo("tonic")

    assert {:ok, %{pod: pod, env: env}} = start(%{ctx | services: services})

    script = ~S"""
    set -e
    echo "pg=$(psql "$DATABASE_URL" -tA -c 'show server_version' | cut -d. -f1)"
    wget -q -T 5 -O /dev/null "$S3_ENDPOINT/minio/health/ready" && echo s3=ready
    """

    assert {:ok, {out, 0}} =
             Container.run(["sh", "-c", script],
               worktree: ctx.dir,
               name: ctx.name,
               image: @image,
               pod: pod,
               env: env
             )

    assert out =~ "pg=15"
    assert out =~ "s3=ready"
    assert :ok = TestServices.stop(pod)
  end

  test "the pod's services are not reachable from the host either (no published ports)", ctx do
    assert {:ok, %{pod: pod}} = start(ctx)

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, 5432, [active: false], 2_000)

    assert :ok = TestServices.stop(pod)
  end

  test "the egress bridge sockets still work from inside the pod (label=disable, design §5.3)",
       ctx do
    # A unix socket with a listener in this (unconfined) process, as the
    # egress proxy's is. `psql -h <dir>` connect()s to `<dir>/.s.PGSQL.5432`;
    # under a confined label that is `Permission denied`.
    sock_dir = Path.join(ctx.dir, "b")
    File.mkdir_p!(sock_dir)
    sock = Path.join(sock_dir, ".s.PGSQL.5432")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(sock)}])

    on_exit(fn -> :gen_tcp.close(listener) end)

    acceptor =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.accept(listener, 60_000)
        :gen_tcp.close(conn)
      end)

    assert {:ok, %{pod: pod}} = start(ctx)

    assert {:ok, {out, _status}} =
             Container.run(
               ["psql", "-h", sock_dir, "-U", "x", "-c", "select 1"],
               worktree: ctx.dir,
               name: ctx.name,
               image: @image,
               pod: pod,
               bridges: [sock]
             )

    # Connected (the listener hung up on the startup packet), not denied.
    assert out =~ "server closed the connection unexpectedly"
    refute out =~ "Permission denied"
    Task.await(acceptor)
    assert :ok = TestServices.stop(pod)
  end

  test "a service that exits at once fails the start and leaves no pod", ctx do
    {:ok, services} =
      TestServices.resolve([
        %{name: "broken", image: @image, command: ["false"], ready: ["true"]}
      ])

    assert {:error, {:service_not_ready, "broken", _}} =
             start(%{ctx | services: services}, ready_timeout_ms: 3_000)

    refute pod_exists?(ctx.pod)
    refute container_exists?(TestServices.service_name(ctx.name, hd(services)))
  end

  test "a worker that dies by any means takes the pod with it (Reaper)", ctx do
    assert {:ok, %{pod: pod}} = start(ctx)
    assert pod_exists?(pod)

    owner = spawn(fn -> receive do: (:never -> :ok) end)
    :ok = Reaper.track(owner, pod)

    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    await(fn -> not pod_exists?(pod) end)
    refute container_exists?(TestServices.service_name(ctx.name, hd(ctx.services)))
  end

  test "a failed worker command still leaves the pod to be torn down, and teardown is idempotent",
       ctx do
    assert {:ok, %{pod: pod, env: env}} = start(ctx)

    assert {:ok, {_out, 7}} =
             Container.run(["sh", "-c", "exit 7"],
               worktree: ctx.dir,
               name: ctx.name,
               image: @image,
               pod: pod,
               env: env
             )

    assert pod_exists?(pod)
    assert :ok = Arbiter.Worker.ContainerSpawn.teardown(%{sandbox: %{name: ctx.name, pod: pod}})
    refute pod_exists?(pod)
    assert :ok = TestServices.stop(pod)
  end

  test "reap_orphans removes a pod whose server pid is gone, and keeps a live server's", ctx do
    assert {:ok, %{pod: pod}} = start(ctx)

    assert [] = TestServices.reap_orphans(alive?: fn _ -> true end)
    assert pod_exists?(pod)

    assert pod in TestServices.reap_orphans(alive?: fn _ -> false end)
    refute pod_exists?(pod)
  end
end
