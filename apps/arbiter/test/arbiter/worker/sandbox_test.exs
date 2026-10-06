defmodule Arbiter.Worker.SandboxTest do
  @moduledoc """
  bd-btcdrf (P2): the `Arbiter.Worker.Sandbox` behaviour and its backend
  selection. `Jail` (bwrap) is the only implementation; `podman` is accepted
  by the policy but refused here until `Arbiter.Worker.Container` exists.
  """

  # async: false — toggles the jail's availability override.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.Sandbox

  defp policy(backend),
    do: SecurityPolicy.merge(SecurityPolicy.base(), %{sandbox: %{backend: backend}})

  setup do
    prev = Application.get_env(:arbiter, :worker_jail_available)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:arbiter, :worker_jail_available),
        else: Application.put_env(:arbiter, :worker_jail_available, prev)
    end)
  end

  describe "Jail as an implementation" do
    test "declares the Sandbox behaviour and implements every callback" do
      assert Sandbox in (Jail.module_info(:attributes)
                         |> Keyword.get_values(:behaviour)
                         |> List.flatten())

      for {fun, arity} <- Sandbox.behaviour_info(:callbacks) do
        assert function_exported?(Jail, fun, arity), "Jail.#{fun}/#{arity} missing"
      end
    end

    test "teardown/1 is a no-op: bwrap dies with its parent" do
      assert Jail.teardown(make_ref()) == :ok
    end
  end

  describe "backend resolution" do
    test "bwrap resolves to Jail, and the default policy is bwrap" do
      assert Sandbox.module(:bwrap) == {:ok, Jail}
      assert Sandbox.module(SecurityPolicy.base()) == {:ok, Jail}
      assert Sandbox.module(SecurityPolicy.default()) == {:ok, Jail}
      assert Sandbox.module(policy(:bwrap)) == {:ok, Jail}
    end

    test "podman is refused with a message that names the backend and the fix" do
      assert {:error, {:sandbox_backend_unavailable, :podman, message}} =
               Sandbox.module(:podman)

      assert message =~ "podman"
      assert message =~ "not implemented"
      assert message =~ "sandbox.backend"
      assert Sandbox.module(policy(:podman)) == Sandbox.module(:podman)
    end

    # bd-d2o3xb (P7), bd-50d5j6 (P8): Claude and Codex have a podman wrap point.
    test "module/2 resolves podman for claude and codex only" do
      for provider <- [:claude, "claude", :codex, "codex"] do
        assert Sandbox.module(:podman, provider) == {:ok, Arbiter.Worker.Container}
        assert Sandbox.module(policy(:podman), provider) == {:ok, Arbiter.Worker.Container}
      end

      for provider <- [:gemini, "gemini"] do
        assert {:error, {:sandbox_backend_unavailable, :podman, message}} =
                 Sandbox.module(policy(:podman), provider)

        assert message =~ "claude and codex only"
      end
    end

    test "module/2 is module/1 for every other backend" do
      assert Sandbox.module(:bwrap, :claude) == {:ok, Jail}
      assert Sandbox.module(policy(:bwrap), :gemini) == {:ok, Jail}

      assert {:error, {:sandbox_backend_unavailable, :docker, _}} =
               Sandbox.module(:docker, :claude)
    end

    test "an unknown backend is refused, never mapped to a default" do
      assert {:error, {:sandbox_backend_unavailable, :docker, _}} = Sandbox.module(:docker)
    end
  end

  describe "delegation under the default backend" do
    test "status/1 and network_status/1 are Jail's" do
      Application.put_env(:arbiter, :worker_jail_available, true)
      assert Sandbox.status(SecurityPolicy.base()) == :ok

      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Sandbox.status(SecurityPolicy.base()) == Jail.status()
      assert Sandbox.network_status(SecurityPolicy.base()) == Jail.network_status()
    end

    test "wrap/3 returns exactly what Jail.wrap/2 returns, success and refusal" do
      dir = Path.join(System.tmp_dir!(), "sandbox-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      opts = [worktree: dir, writable_paths: ["/opt/x"], env: [{"A", "b"}]]
      command = ["echo", "hi"]

      assert Sandbox.wrap(SecurityPolicy.base(), command, opts) == Jail.wrap(command, opts)
      assert Sandbox.wrap(policy(:bwrap), command, opts) == Jail.wrap(command, opts)

      assert Sandbox.wrap(SecurityPolicy.base(), command, []) == Jail.wrap(command, [])
      assert {:error, _} = Sandbox.wrap(SecurityPolicy.base(), command, [])
    end
  end

  describe "podman with no implementation" do
    test "every entry point refuses and none returns an argv" do
      podman = policy(:podman)

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} = Sandbox.status(podman)
      assert {:error, {:sandbox_backend_unavailable, :podman, _}} = Sandbox.network_status(podman)

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
               Sandbox.wrap(podman, ["echo", "hi"], worktree: System.tmp_dir!())
    end

    test "the refusal does not depend on whether bwrap works on this host" do
      podman = policy(:podman)

      for available <- [true, false] do
        Application.put_env(:arbiter, :worker_jail_available, available)

        assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
                 Sandbox.wrap(podman, ["echo"], worktree: System.tmp_dir!())
      end
    end

    test "teardown/2 on podman is a no-op, since nothing was started" do
      assert Sandbox.teardown(policy(:podman), "ref") == :ok
    end
  end
end
