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
    readiness: 0
  ]
  # bd-9rrrgk: optional; a backend without it answers `{:error, :unsupported}`.
  @optional [exec: 4]

  defp load(extra_env \\ %{}) do
    Config.load(
      env:
        Map.merge(%{"ARB_NODE_URL" => "https://p.example.ts.net", "HOME" => "/home/x"}, extra_env),
      app_config: [],
      read_credential: fn _ -> {:ok, @credential} end
    )
  end

  test "the behaviour declares the ten callbacks, plus the optional exec" do
    assert Enum.sort(Backend.behaviour_info(:callbacks)) == Enum.sort(@callbacks ++ @optional)
    assert Backend.behaviour_info(:optional_callbacks) == @optional
  end

  test "the podman backend implements every callback" do
    Code.ensure_loaded!(Backend.Podman)

    for {fun, arity} <- @callbacks ++ @optional do
      assert function_exported?(Backend.Podman, fun, arity), "#{fun}/#{arity} missing"
    end

    assert Backend.Podman.list_owned() == []
    assert Backend.Podman.inventory() == []
    assert is_map(Backend.Podman.capacity())
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
