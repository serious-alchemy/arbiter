defmodule Arbiter.NodeAgent.K8s.UpgraderTest do
  @moduledoc """
  A cluster node's self-upgrade (`docs/design/remote-workers.md` K§2.4 step 3, ticket K14):
  `hello_ok.upgrade{version, image}` reaches `Arbiter.NodeAgent.K8s.Upgrader` through the
  same `request/2` call the machine's tarball upgrader answers; when idle (no live run), it
  patches the controller's own Deployment (`Arbiter.NodeAgent.K8s.SelfUpgrade`) and the
  `Recreate` strategy restarts it on the new image.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Arbiter.NodeAgent.K8s.Upgrader
  alias Arbiter.NodeAgent.Status
  alias Arbiter.Test.FakeK8sApi

  @old "registry.example.test/arbiter/controller:0.2.42"
  @new "registry.example.test/arbiter/controller:0.2.43"
  @spec_new %{"version" => "0.2.43", "image" => @new}

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arbiter-workers")

    FakeK8sApi.put_deployment(env.api, %{
      "metadata" => %{"name" => "arbiter-controller", "namespace" => "arbiter-workers"},
      "spec" => %{
        "template" => %{"spec" => %{"containers" => [%{"name" => "controller", "image" => @old}]}}
      }
    })

    status_name = :"status_#{System.unique_integer([:positive])}"
    path = Path.join(dir, "status.json")
    start_supervised!({Status, path: path, name: status_name})
    idle = start_supervised!({Agent, fn -> true end})

    Map.merge(env, %{status: status_name, status_path: path, idle: idle})
  end

  defp start!(env, extra \\ []) do
    start_supervised!(
      {Upgrader,
       Keyword.merge(
         [
           client: env.client,
           version: "0.2.42",
           status: env.status,
           enabled?: true,
           idle_fun: fn -> Agent.get(env.idle, & &1) end,
           retry_ms: 20,
           name: nil
         ],
         extra
       )}
    )
  end

  defp image(env),
    do:
      env.api
      |> FakeK8sApi.deployment("arbiter-controller")
      |> get_in(["spec", "template", "spec", "containers"])
      |> hd()
      |> Map.fetch!("image")

  defp upgrade_status(env), do: Status.get(env.status)["upgrade"]

  defp patches(env), do: Enum.count(FakeK8sApi.requests(env.api), &(&1.method == "PATCH"))

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "a request for the running version is ignored", env do
    up = start!(env)
    assert :ignored = Upgrader.request(up, %{"version" => "v0.2.42", "image" => @old})
    assert patches(env) == 0
  end

  test "when idle, the controller's own Deployment is patched to the new image", env do
    up = start!(env)

    assert :started = Upgrader.request(up, @spec_new)
    assert image(env) == @new
    assert %{"state" => "patched", "version" => "0.2.43", "image" => @new} = upgrade_status(env)
  end

  test "while a run is live it waits, then patches once the controller is idle", env do
    Agent.update(env.idle, fn _ -> false end)
    up = start!(env)

    assert :started = Upgrader.request(up, @spec_new)
    assert %{"state" => "waiting_for_idle"} = upgrade_status(env)
    assert image(env) == @old

    Agent.update(env.idle, fn _ -> true end)
    # The status is written after the PATCH returns: wait for it, not for the image.
    wait_until(fn -> upgrade_status(env)["state"] == "patched" end)
    assert image(env) == @new
  end

  test "the same request again (every hello_ok repeats it) is not a second attempt", env do
    Agent.update(env.idle, fn _ -> false end)
    up = start!(env)

    assert :started = Upgrader.request(up, @spec_new)
    assert :ignored = Upgrader.request(up, @spec_new)
  end

  test "without ARB_K8S_SELF_UPGRADE=true nothing is patched and the status says so", env do
    up = start!(env, enabled?: false)

    assert :started = Upgrader.request(up, @spec_new)
    assert %{"state" => "disabled"} = upgrade_status(env)
    assert patches(env) == 0
    assert :ignored = Upgrader.request(up, @spec_new)
  end

  test "a tarball upgrade (a machine's) is not this node's to take", env do
    up = start!(env)

    assert :ignored =
             Upgrader.request(up, %{"version" => "0.2.43", "sha256" => String.duplicate("a", 64)})
  end

  test "a refused patch is a failed upgrade, retried later", env do
    FakeK8sApi.fail_next(env.api, :deployment_patch, {403, "deployments is forbidden"})
    up = start!(env)

    assert :started = Upgrader.request(up, @spec_new)
    assert %{"state" => "failed", "error" => error} = upgrade_status(env)
    assert error =~ "forbidden"

    wait_until(fn -> upgrade_status(env)["state"] == "patched" end)
    assert image(env) == @new
  end
end
