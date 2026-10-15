defmodule Arbiter.NodeAgent.BackendTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Backend
  alias Arbiter.NodeAgent.Config

  @credential "arbn_node123." <> String.duplicate("A", 52)
  @callbacks [
    inventory: 0,
    start_run: 1,
    signal: 2,
    stop: 1,
    outcome: 1,
    collect: 2,
    list_owned: 0,
    reap: 1,
    capacity: 0,
    readiness: 0,
    # K14: what `Connection` does to the runs on the channel's events, so it speaks only
    # to the backend (the machine's own `Run`/`Runs` calls moved behind it unchanged).
    hello: 2,
    heartbeat: 2,
    attach: 1,
    attach_all: 1,
    detach_all: 0,
    fence_all: 0,
    ack: 2,
    exit_ack: 1,
    quiesce: 1,
    adopt: 1
  ]
  # bd-9rrrgk: optional; a backend without it answers `{:error, :unsupported}`.
  # K15: `resume/1` is optional too (only a backend with opaque stdout cursors has it).
  @optional [exec: 4, resume: 1]

  defp load(extra_env \\ %{}) do
    Config.load(
      env:
        Map.merge(%{"ARB_NODE_URL" => "https://p.example.ts.net", "HOME" => "/home/x"}, extra_env),
      app_config: [],
      read_credential: fn _ -> {:ok, @credential} end
    )
  end

  test "the behaviour declares its callbacks, plus the optional exec and resume" do
    assert Enum.sort(Backend.behaviour_info(:callbacks)) == Enum.sort(@callbacks ++ @optional)
    assert Enum.sort(Backend.behaviour_info(:optional_callbacks)) == Enum.sort(@optional)
  end

  test "the podman backend implements every callback" do
    Code.ensure_loaded!(Backend.Podman)

    # a machine's byte offsets need no `resume/1`
    for {fun, arity} <- @callbacks ++ [exec: 4] do
      assert function_exported?(Backend.Podman, fun, arity), "#{fun}/#{arity} missing"
    end

    assert Backend.Podman.list_owned() == []
    assert Backend.Podman.inventory() == []
    assert is_map(Backend.Podman.capacity())
  end

  test "the podman hooks are the machine agent's own calls, unchanged" do
    {:ok, config} = load()

    # The same payloads `Protocol` has always built for a machine.
    assert Backend.Podman.hello(config, %{"ready" => true}) ==
             Arbiter.NodeAgent.Protocol.hello(config, %{"ready" => true})

    assert %{"seq" => 7, "runs" => []} = Backend.Podman.heartbeat(config, 7)

    # No run table running: nothing to attach, detach or fence.
    assert Backend.Podman.attach_all([]) == :ok
    assert Backend.Podman.detach_all() == :ok
    assert Backend.Podman.fence_all() == :ok
  end

  describe "the podman per-run hooks" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Arbiter.NodeAgent.RunRegistry})
      me = self()

      # Stands in for the run's `Run` process: registered under its id, it reports the
      # casts `Arbiter.NodeAgent.Run` sends.
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Arbiter.NodeAgent.RunRegistry, "r1", nil)
           send(me, :registered)
           relay(me)
         end}
      )

      assert_receive :registered
      :ok
    end

    defp relay(to) do
      receive do
        {:"$gen_cast", message} -> send(to, {:cast, message})
      end

      relay(to)
    end

    test "reach the run's own process, as Connection's direct calls did" do
      assert Backend.Podman.attach("r1") == :ok
      assert_receive {:cast, :attach}
      assert Backend.Podman.ack("r1", 10) == :ok
      assert_receive {:cast, {:ack, 10}}
      assert Backend.Podman.exit_ack("r1") == :ok
      assert_receive {:cast, :ack_exit}
      assert Backend.Podman.quiesce("r1") == :ok
      assert_receive {:cast, :quiesce}
      assert Backend.Podman.adopt("r1") == :ok
      assert_receive {:cast, :adopt}
    end

    test "an unknown run is {:error, :not_found}" do
      for hook <- [&Backend.Podman.attach/1, &Backend.Podman.quiesce/1, &Backend.Podman.adopt/1],
          do: assert(hook.("r9") == {:error, :not_found})
    end

    test "attach_all and fence_all go to every run but the skipped ones" do
      assert Backend.Podman.attach_all(["r1"]) == :ok
      refute_received {:cast, _}
      assert Backend.Podman.attach_all([]) == :ok
      assert_receive {:cast, :attach}
      assert Backend.Podman.detach_all() == :ok
      assert_receive {:cast, :detach}
      assert Backend.Podman.fence_all() == :ok
      assert_receive {:cast, {:cancel, "fenced"}}
    end
  end

  test "ARB_AGENT_BACKEND defaults to podman" do
    assert {:ok, %Config{backend: Backend.Podman}} = load()
  end

  test "ARB_AGENT_BACKEND=podman selects the podman backend" do
    assert {:ok, %Config{backend: Backend.Podman}} = load(%{"ARB_AGENT_BACKEND" => "podman"})
  end

  test "an unknown ARB_AGENT_BACKEND is an error" do
    assert {:error, {:unknown_backend, "docker"}} = load(%{"ARB_AGENT_BACKEND" => "docker"})
  end

  test "an unknown backend fails the agent supervisor at boot" do
    assert_raise ArgumentError, ~r/ARB_AGENT_BACKEND/, fn ->
      Arbiter.NodeAgent.Supervisor.init(
        env: %{"ARB_AGENT_BACKEND" => "docker", "ARB_NODE_URL" => "https://p.example.ts.net"},
        app_config: [],
        read_credential: fn _ -> {:ok, @credential} end
      )
    end
  end
end
