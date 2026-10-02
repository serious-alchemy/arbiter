defmodule Arbiter.Worker.Egress.SelfTestTest do
  @moduledoc """
  bd-5yydxh (G10): the doctor's "egress jail" self-test. It stands a proxy up
  against a local stand-in server (loopback, no internet) and expects exactly
  one allow and one deny. The jail-presence half is injected as `:probe`, so
  these run on any host; the real probe is exercised by one test that accepts
  either outcome, since whether a host can jail is a property of the host.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Worker.Egress.{Event, SelfTest}
  alias Arbiter.Worker.Jail

  defp ok_probe, do: fn -> :ok end

  describe "run/1" do
    test "sees 1 allow and 1 deny against the local stand-in" do
      assert {:ok, %{allowed: 1, denied: 1}} = SelfTest.run(probe: ok_probe())
    end

    test "leaves no proxy run, socket file or egress_events row behind" do
      before_count = length(Ash.read!(Event))

      assert {:ok, _} = SelfTest.run(probe: ok_probe())

      assert length(Ash.read!(Event)) == before_count
      dir = Arbiter.Worker.Egress.socket_dir()

      leftovers =
        if File.dir?(dir),
          do: Enum.filter(File.ls!(dir), &String.starts_with?(&1, "selftest")),
          else: []

      assert leftovers == []
    end

    test "a proxy that lets the deny through fails the self-test" do
      # Learn mode dials the denied port (nothing listens there, so 502); what
      # matters is that it is not the 403 a filtering proxy answers.
      assert {:error, {:deny_failed, got}} = SelfTest.run(probe: ok_probe(), enforce: false)
      assert got in [200, 502]
    end

    test "a missing jail prerequisite short-circuits before any proxy starts" do
      probe = fn -> {:error, :socat_not_found} end

      assert {:error, {:jail, :socat_not_found}} = SelfTest.run(probe: probe)
    end

    test "a proxy that cannot start is reported, not raised" do
      assert {:error, {:proxy_start, :invalid_run_id}} =
               SelfTest.run(probe: ok_probe(), run_id: "bad id!")
    end
  end

  describe "diagnose/1" do
    test "nil when the self-test passes" do
      assert SelfTest.diagnose(probe: ok_probe()) == nil
    end

    test "names the missing package when socat is absent, as Jail.explain_network/1 does" do
      diagnosis = SelfTest.diagnose(probe: fn -> {:error, :socat_not_found} end)

      assert diagnosis == Jail.explain_network(:socat_not_found)
      assert diagnosis.fix =~ "socat"
    end

    test "names bubblewrap when bwrap is absent" do
      diagnosis = SelfTest.diagnose(probe: fn -> {:error, {:bwrap_not_found, "bwrap"}} end)

      assert diagnosis.cause == :bwrap_missing
      assert diagnosis.fix =~ "bubblewrap"
    end

    test "names the sysctl when the netns cannot start" do
      diagnosis =
        SelfTest.diagnose(
          probe: fn -> {:error, {:netns_failed, 1, "Operation not permitted"}} end
        )

      assert diagnosis.cause == :netns_unavailable
      assert diagnosis.fix =~ "user.max_user_namespaces"
    end

    test "a proxy that does not start has a cause and a message" do
      diagnosis = SelfTest.diagnose(probe: ok_probe(), run_id: "bad id!")

      assert diagnosis.cause == :egress_proxy
      assert diagnosis.message =~ "proxy"
    end

    test "an allow that came back denied (or a deny that came back allowed) is a failure" do
      assert %{cause: :egress_proxy, message: allow_msg} =
               SelfTest.explain({:allow_failed, 403})

      assert allow_msg =~ "allow"

      assert %{cause: :egress_proxy, message: deny_msg} = SelfTest.explain({:deny_failed, 200})
      assert deny_msg =~ "deny"
    end
  end

  describe "run/1 with the real jail probe" do
    test "passes where the host can jail in a network namespace, else explains why" do
      case SelfTest.run([]) do
        {:ok, %{allowed: 1, denied: 1}} ->
          assert SelfTest.diagnose([]) == nil

        {:error, reason} ->
          assert %{message: message} = SelfTest.explain(reason)
          assert is_binary(message)
      end
    end
  end
end
