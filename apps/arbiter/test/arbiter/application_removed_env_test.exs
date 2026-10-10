defmodule Arbiter.ApplicationRemovedEnvTest do
  # Mutates the global app env, so it cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Application

  setup do
    previous = Elixir.Application.fetch_env(:arbiter, :conductor_system_max_concurrent)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Elixir.Application.put_env(:arbiter, :conductor_system_max_concurrent, value)

        :error ->
          Elixir.Application.delete_env(:arbiter, :conductor_system_max_concurrent)
      end
    end)

    :ok
  end

  describe "warn_removed_env/0 (DC1, §10.6)" do
    test "logs the advisory with the node command when the removed app env is set" do
      Elixir.Application.put_env(:arbiter, :conductor_system_max_concurrent, 4)

      log =
        capture_log([level: :warning], fn ->
          assert Application.warn_removed_env() == :ok
        end)

      assert log =~ ":conductor_system_max_concurrent (4) is no longer read"
      assert log =~ "arb node set local --max-workers 4"
    end

    test "is silent when the app env is unset" do
      Elixir.Application.delete_env(:arbiter, :conductor_system_max_concurrent)

      log =
        capture_log([level: :warning], fn ->
          assert Application.warn_removed_env() == :ok
        end)

      refute log =~ "conductor_system_max_concurrent"
    end
  end
end
