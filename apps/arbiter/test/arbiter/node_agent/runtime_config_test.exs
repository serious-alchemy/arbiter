defmodule Arbiter.NodeAgent.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` is gated on `ARB_ROLE` (docs/design/remote-workers.md §3):
  an agent has no `SECRET_KEY_BASE`, no database and no cloak key, so none of
  the primary's runtime config (the `SECRET_KEY_BASE` raise, the Repo) may be
  evaluated for it. The default boot keeps its guard.
  """
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../../config/runtime.exs", __DIR__)
  @env_vars ~w(ARB_ROLE SECRET_KEY_BASE DATABASE_PATH ARBITER_CLOAK_KEY)

  setup do
    saved = for name <- @env_vars, do: {name, System.get_env(name)}
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- saved do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  defp read(env), do: Config.Reader.read!(@runtime, env: env, target: :host)

  test "ARB_ROLE=agent boots a prod config without SECRET_KEY_BASE, a DB path or the cloak key" do
    System.put_env("ARB_ROLE", "agent")

    config = read(:prod)

    assert config[:arbiter][:role] == :agent
    refute Keyword.has_key?(config[:arbiter] || [], Arbiter.Repo)
    refute config[:arbiter_web][ArbiterWeb.Endpoint][:secret_key_base]
    refute config[:arbiter_web][ArbiterWeb.Endpoint][:server]
  end

  test "the same gate applies in dev, which also raises on a missing SECRET_KEY_BASE" do
    System.put_env("ARB_ROLE", "agent")
    assert read(:dev)[:arbiter][:role] == :agent
  end

  test "the default (primary) prod boot still refuses to start without SECRET_KEY_BASE" do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE is missing/, fn -> read(:prod) end
  end

  test "ARB_ROLE=primary is the default boot, unchanged" do
    System.put_env("ARB_ROLE", "primary")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))

    config = read(:prod)

    assert config[:arbiter][:role] == :primary
    assert config[:arbiter][Arbiter.Repo][:database]

    assert config[:arbiter_web][ArbiterWeb.Endpoint][:secret_key_base] ==
             String.duplicate("k", 64)

    assert config[:arbiter_web][ArbiterWeb.Endpoint][:server] == true
  end

  test "an unset ARB_ROLE writes no role, so the application default (primary) applies" do
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    refute Keyword.has_key?(read(:prod)[:arbiter], :role)
  end

  test "an unknown ARB_ROLE refuses to boot rather than falling back to primary" do
    System.put_env("ARB_ROLE", "agnet")
    System.put_env("SECRET_KEY_BASE", String.duplicate("k", 64))
    assert_raise RuntimeError, ~r/ARB_ROLE/, fn -> read(:prod) end
  end
end
