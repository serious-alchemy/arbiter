defmodule Arbiter.NodeAgent do
  @moduledoc """
  The node agent: the Arbiter release run in the `agent` role
  (`docs/design/remote-workers.md` §3, §4.2, §6).

  A node runs the same release as the primary with `ARB_ROLE=agent`.
  `config/runtime.exs` turns that variable into `config :arbiter, role: :agent`;
  this module is the one place the role is read back. Both
  `Arbiter.Application.start/2` and `ArbiterWeb.Application.start/2` ask
  `role/0` first and **match positively** on the answer: `:agent` starts only
  `Arbiter.NodeAgent.Supervisor`, `:primary` starts today's list, and anything
  else refuses to boot. A child added to the primary list later therefore never
  runs on a node, and a typo in the role never boots as a primary.

  The namespace is `Arbiter.NodeAgent`, not `Arbiter.Agents`, which holds the
  provider adapters.
  """

  @type role :: :primary | :agent

  @doc """
  The configured role. `{:ok, :primary}` when nothing configured one (the
  default boot); `{:error, {:unknown_role, value}}` for anything but
  `:primary` / `:agent`.
  """
  @spec role() :: {:ok, role()} | {:error, {:unknown_role, term()}}
  def role do
    case Application.get_env(:arbiter, :role, :primary) do
      role when role in [:primary, :agent] -> {:ok, role}
      other -> {:error, {:unknown_role, other}}
    end
  end

  @doc "True when this VM was booted as a node agent."
  @spec agent?() :: boolean()
  def agent?, do: role() == {:ok, :agent}
end
