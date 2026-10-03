defmodule Arbiter.Worker.ContainerPodmanTest do
  @moduledoc """
  bd-bu4ye2 (P3): `Arbiter.Worker.Container` against a REAL rootless podman.

  Opt-in (`@moduletag :podman`), because it starts containers and needs a
  ready podman plus a local `#{"docker.io/library/debian:12"}` image:

      cd apps/arbiter && mix test --include podman test/arbiter/worker/container_podman_test.exs

  Every container is named `arb-test-…` and removed by that exact name: never a
  pattern kill (this repo's coordinator runs on the same host).
  """
  use ExUnit.Case, async: false

  alias Arbiter.Worker.Container

  @moduletag :podman
  @moduletag timeout: 180_000
  @image "docker.io/library/debian:12"

  setup do
    {_, 0} = System.cmd("podman", ["image", "exists", @image])
    dir = Path.join(System.tmp_dir!(), "arb-podman-t-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    name = Container.name_for("test-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Container.stop(name)
      File.rm_rf!(dir)
    end)

    %{dir: dir, name: name}
  end

  defp opts(ctx, extra \\ []),
    do: Keyword.merge([worktree: ctx.dir, name: ctx.name, image: @image], extra)

  defp exists?(name), do: match?({_, 0}, System.cmd("podman", ["container", "exists", name]))

  # Poll for a condition on a short fuse without `Process.sleep`.
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

  test "the sandbox is what the argv says: host uid, read-only root, no caps, no inherited env",
       ctx do
    System.put_env("ARB_PODMAN_TEST_LEAK", "leaked")
    on_exit(fn -> System.delete_env("ARB_PODMAN_TEST_LEAK") end)
    {host_uid, 0} = System.cmd("id", ["-u"])

    script =
      ~S"""
      echo "uid=$(id -u)"
      echo "leak=${ARB_PODMAN_TEST_LEAK-unset}"
      echo "token=${ARB_PODMAN_TEST_TOKEN-unset}"
      echo "literal=${ARB_PODMAN_TEST_LITERAL-unset}"
      touch /rootfs-write 2>/dev/null; echo "rootfs_rc=$?"
      touch "$PWD/ok" ; echo "worktree_rc=$?"
      grep CapEff /proc/self/status
      ls /home /root 2>&1 | head -1
      """

    assert {:ok, {out, 0}} =
             Container.run(
               ["sh", "-c", script],
               opts(ctx,
                 env: [{"ARB_PODMAN_TEST_LITERAL", "lit"}],
                 secret_env: [{"ARB_PODMAN_TEST_TOKEN", "tok-123"}]
               )
             )

    assert out =~ "uid=#{String.trim(host_uid)}"
    assert out =~ "leak=unset"
    assert out =~ "token=tok-123"
    assert out =~ "literal=lit"
    assert out =~ "rootfs_rc=1"
    assert out =~ "worktree_rc=0"
    assert out =~ "CapEff:\t0000000000000000"
    assert File.exists?(Path.join(ctx.dir, "ok"))
    refute exists?(ctx.name)
  end

  test "no network: only lo", ctx do
    assert {:ok, {out, 0}} =
             Container.run(["sh", "-c", "ls /sys/class/net"], opts(ctx))

    assert String.trim(out) == "lo"
  end

  test "a non-zero exit is returned and the container is gone", ctx do
    assert {:ok, {_out, 7}} = Container.run(["sh", "-c", "exit 7"], opts(ctx))
    refute exists?(ctx.name)
  end

  test "a timeout ends the spawn and removes the still-running container", ctx do
    assert {:error, :timeout} =
             Container.run(["sleep", "300"], opts(ctx, timeout: 5_000))

    refute exists?(ctx.name)
  end

  # The design's §6.4 probe saw `kill -KILL` of the client leave the container
  # running; podman 5.8.7 with a Port-attached client removed it within a
  # second (checked by hand). The behaviour is podman's to change, so this
  # asserts the property that matters: teardown by name leaves nothing, and is
  # idempotent, whichever way the kill went.
  test "after the podman client is SIGKILLed, teardown by name leaves no container (§6.4)",
       ctx do
    {:ok, [podman | args]} = Container.wrap(["sleep", "300"], opts(ctx))
    port = Port.open({:spawn_executable, podman}, [:binary, :exit_status, args: args])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    await(fn -> exists?(ctx.name) end)

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, _}}, 10_000

    assert :ok = Container.stop(ctx.name)
    refute exists?(ctx.name)
    # Idempotent: removing a name that is already gone is not an error.
    assert :ok = Container.stop(ctx.name)
  end

  test "teardown/1 stops an --init container whose PID 1 would ignore SIGTERM", ctx do
    {:ok, [podman | args]} = Container.wrap(["sleep", "300"], opts(ctx))
    port = Port.open({:spawn_executable, podman}, [:binary, :exit_status, args: args])

    await(fn -> exists?(ctx.name) end)
    started = System.monotonic_time(:millisecond)
    assert :ok = Container.teardown(ctx.name)
    assert System.monotonic_time(:millisecond) - started < 5_000
    refute exists?(ctx.name)
    assert_receive {^port, {:exit_status, _}}, 10_000
  end

  test "status/0 finds this host ready" do
    Container.reset()
    assert Container.status() == :ok
  end
end
