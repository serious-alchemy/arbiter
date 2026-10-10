defmodule Arbiter.Worker.ReleaseEnvAgentVarsTest do
  @moduledoc """
  RW5 (docs/design/remote-workers.md §3): the node agent is the release run with
  `ARB_ROLE=agent`. A process it spawns that boots a BEAM (`mix test` in a
  worktree) must not inherit the role, or `config/runtime.exs` would turn that
  VM into an agent too. The agent's own settings go with it.
  """
  # Mutates the process environment.
  use ExUnit.Case, async: false

  alias Arbiter.Worker.ReleaseEnv

  @vars ~w(ARB_ROLE ARB_NODE_URL ARB_NODE_HOME ARB_NODE_CREDENTIAL_FILE ARB_AGENT_BACKEND)

  setup do
    saved = for name <- @vars, do: {name, System.get_env(name)}

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  test "clean_pairs/0 unsets the agent role and its settings when they are set" do
    for name <- @vars, do: System.put_env(name, "x")

    pairs = ReleaseEnv.clean_pairs()

    for name <- @vars, do: assert({name, false} in pairs)
  end

  test "port_env/1 and cmd_env/1 carry the same scrub" do
    System.put_env("ARB_ROLE", "agent")

    assert {"ARB_ROLE", false} in ReleaseEnv.port_env()
    assert {"ARB_ROLE", nil} in ReleaseEnv.cmd_env()
  end

  test "a spawned child really does not see ARB_ROLE" do
    System.put_env("ARB_ROLE", "agent")

    {out, 0} = ReleaseEnv.cmd("sh", ["-c", ~S(printf '%s' "${ARB_ROLE:-unset}")])
    assert out == "unset"
  end

  test "nothing is added when the variables are not set" do
    for name <- @vars, do: System.delete_env(name)
    refute Enum.any?(ReleaseEnv.clean_pairs(), fn {name, _} -> name in @vars end)
  end
end
