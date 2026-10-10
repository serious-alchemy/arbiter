defmodule Arbiter.NodeAgent.PodChannel.RunsTest do
  @moduledoc """
  The controller's table of the runs it assigned (`docs/design/remote-workers.md`
  §16 K§9.3): who may use the pod channel, as which bridge, from where, and
  until when. A leaf certificate chains to the CA for *any* run the CA ever
  signed for; this table is what makes it "a live run this controller assigned".
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.{Cert, Runs}
  alias Arbiter.NodeAgent.RunSpec

  @pod_ip {10, 42, 0, 61}

  defp spec!(run \\ "run-1", bridges \\ ["proxy", "arb"]) do
    {:ok, spec} =
      RunSpec.validate(%{
        "version" => 1,
        "run" => run,
        "task" => "bd-abc",
        "name" => "arb-#{run}",
        "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [%{"kind" => "worktree", "path" => "/work/tree"}],
        "bridges" => Enum.map(bridges, &%{"name" => &1, "path" => "/var/eg/#{&1}.sock"}),
        "secrets" => %{"TOKEN" => "s3cret"},
        "command" => ["claude"]
      })

    spec
  end

  setup do
    now = DateTime.utc_now()
    ca = Cert.ca(DateTime.add(now, -60), DateTime.add(now, 3600))
    server = start_supervised!({Runs, ca: ca, name: nil})
    %{server: server, ca: ca, deadline: DateTime.add(now, 600)}
  end

  # The leaf the pod would hold, read back out of the `/boot` tar.
  defp boot!(server, nonce) do
    {:ok, run, tar} = Runs.redeem(server, nonce, @pod_ip)
    {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
    files = Map.new(files, fn {n, b} -> {to_string(n), b} end)
    {run, files}
  end

  defp der(files, ou) do
    [{:Certificate, der, _}] = :public_key.pem_decode(files["tls/#{ou}.crt"])
    der
  end

  describe "register/3" do
    test "returns a boot nonce and mints a leaf per bridge plus the control leaf", ctx do
      assert {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)

      {"run-1", files} = boot!(ctx.server, nonce)

      for ou <- ~w(proxy arb control) do
        assert %{cn: "run-1", ou: ^ou} = Cert.subject(der(files, ou))
        assert {:ok, _} = :public_key.pkix_path_validation(ctx.ca.der, [der(files, ou)], [])
      end
    end

    test "a leaf lasts until the run's deadline", ctx do
      {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)
      {_, files} = boot!(ctx.server, nonce)

      otp = :public_key.pkix_decode_cert(der(files, "proxy"), :otp)
      {:Validity, _, {:utcTime, not_after}} = elem(elem(otp, 1), 5)
      assert to_string(not_after) == Calendar.strftime(ctx.deadline, "%y%m%d%H%M%SZ")
    end

    test "refuses a deadline that has passed", ctx do
      past = DateTime.add(DateTime.utc_now(), -5)
      assert {:error, :deadline_passed} = Runs.register(ctx.server, spec!(), past)
    end

    test "refuses to register a live run twice", ctx do
      {:ok, _} = Runs.register(ctx.server, spec!(), ctx.deadline)
      assert {:error, :already_registered} = Runs.register(ctx.server, spec!(), ctx.deadline)
    end

    test "refuses a spec that names the reserved control bridge", ctx do
      assert {:error, :reserved_bridge_name} =
               Runs.register(ctx.server, spec!("run-1", ["proxy", "control"]), ctx.deadline)
    end
  end

  describe "redeem/3" do
    test "delivers the secrets once, to the pod's IP", ctx do
      {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)

      {"run-1", files} = boot!(ctx.server, nonce)
      assert files["secrets.env"] =~ "s3cret"

      assert {:error, :unknown} = Runs.redeem(ctx.server, nonce, @pod_ip)
    end

    test "refuses another address and spends the nonce", ctx do
      {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)

      assert {:error, :wrong_ip} = Runs.redeem(ctx.server, nonce, {10, 42, 0, 99})
      assert {:error, :unknown} = Runs.redeem(ctx.server, nonce, @pod_ip)
    end

    test "is not possible before the pod's IP is known", ctx do
      {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      assert {:error, :unbound} = Runs.redeem(ctx.server, nonce, @pod_ip)
    end

    test "expires with the boot window", ctx do
      server = start_supervised!({Runs, ca: ctx.ca, name: nil, boot_ttl_ms: 0}, id: :short)
      {:ok, nonce} = Runs.register(server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(server, "run-1", @pod_ip)

      assert {:error, :expired} = Runs.redeem(server, nonce, @pod_ip)
    end
  end

  describe "authorize/4" do
    setup ctx do
      {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)
      {"run-1", files} = boot!(ctx.server, nonce)
      %{files: files}
    end

    test "a minted bridge leaf, from the pod, is let in as that bridge", ctx do
      assert {:ok, %{run: "run-1", name: "proxy"}} =
               Runs.authorize(ctx.server, :bridge, der(ctx.files, "proxy"), @pod_ip)

      assert {:ok, %{run: "run-1", name: "arb"}} =
               Runs.authorize(ctx.server, :bridge, der(ctx.files, "arb"), @pod_ip)
    end

    test "the control leaf is not a bridge, and a bridge leaf is not control", ctx do
      assert {:error, :wrong_purpose} =
               Runs.authorize(ctx.server, :bridge, der(ctx.files, "control"), @pod_ip)

      assert {:error, :wrong_purpose} =
               Runs.authorize(ctx.server, :control, der(ctx.files, "proxy"), @pod_ip)

      assert {:ok, %{run: "run-1"}} =
               Runs.authorize(ctx.server, :control, der(ctx.files, "control"), @pod_ip)
    end

    test "refuses a CA-signed leaf for a run this controller never assigned", ctx do
      now = DateTime.utc_now()

      stray =
        Cert.leaf(ctx.ca, "run-other", "proxy", DateTime.add(now, -60), DateTime.add(now, 60))

      assert {:error, :unknown_run} = Runs.authorize(ctx.server, :bridge, stray.der, @pod_ip)
    end

    test "refuses a CA-signed leaf for a bridge the run's spec never named", ctx do
      now = DateTime.utc_now()
      stray = Cert.leaf(ctx.ca, "run-1", "git", DateTime.add(now, -60), DateTime.add(now, 60))

      assert {:error, :unknown_bridge} = Runs.authorize(ctx.server, :bridge, stray.der, @pod_ip)
    end

    test "refuses a CA-signed leaf for a named bridge that is not the one it minted", ctx do
      now = DateTime.utc_now()
      forged = Cert.leaf(ctx.ca, "run-1", "proxy", DateTime.add(now, -60), DateTime.add(now, 60))

      assert {:error, :leaf_mismatch} = Runs.authorize(ctx.server, :bridge, forged.der, @pod_ip)
    end

    test "refuses the right leaf from another address", ctx do
      assert {:error, :wrong_ip} =
               Runs.authorize(ctx.server, :bridge, der(ctx.files, "proxy"), {10, 42, 0, 99})
    end

    test "refuses everything once the run is released", ctx do
      :ok = Runs.release(ctx.server, "run-1")

      assert {:error, :unknown_run} =
               Runs.authorize(ctx.server, :bridge, der(ctx.files, "proxy"), @pod_ip)

      assert {:error, :unknown_run} =
               Runs.authorize(ctx.server, :control, der(ctx.files, "control"), @pod_ip)
    end

    test "refuses a certificate that is not a certificate", ctx do
      assert {:error, :bad_certificate} = Runs.authorize(ctx.server, :bridge, "garbage", @pod_ip)
    end
  end

  test "a run past its deadline is dropped by the table itself", ctx do
    soon = DateTime.add(DateTime.utc_now(), 1)
    {:ok, _} = Runs.register(ctx.server, spec!(), soon)
    assert_eventually(fn -> Runs.live_runs(ctx.server) == [] end)
  end

  describe "commands" do
    setup ctx do
      {:ok, _} = Runs.register(ctx.server, spec!(), ctx.deadline)
      :ok
    end

    test "a pushed command is handed to the next poll", ctx do
      :ok = Runs.push_command(ctx.server, "run-1", %{"op" => "checkpoint"})
      assert {:ok, [%{"op" => "checkpoint"}]} = Runs.await_commands(ctx.server, "run-1", 100)
      assert {:ok, []} = Runs.await_commands(ctx.server, "run-1", 10)
    end

    test "a poll waits for a command", ctx do
      task = Task.async(fn -> Runs.await_commands(ctx.server, "run-1", 5_000) end)
      assert_eventually(fn -> Runs.waiting(ctx.server, "run-1") == 1 end)

      :ok = Runs.push_command(ctx.server, "run-1", %{"op" => "stop"})
      assert {:ok, [%{"op" => "stop"}]} = Task.await(task)
    end

    test "releasing the run ends a waiting poll", ctx do
      task = Task.async(fn -> Runs.await_commands(ctx.server, "run-1", 5_000) end)
      assert_eventually(fn -> Runs.waiting(ctx.server, "run-1") == 1 end)

      :ok = Runs.release(ctx.server, "run-1")
      assert {:error, :unknown_run} = Task.await(task)
    end

    test "commands for an unknown run are refused", ctx do
      assert {:error, :unknown_run} = Runs.push_command(ctx.server, "nope", %{})
    end
  end

  test "the nonce is not kept in the clear", ctx do
    {:ok, nonce} = Runs.register(ctx.server, spec!(), ctx.deadline)
    :ok = Runs.bind_pod_ip(ctx.server, "run-1", @pod_ip)

    refute inspect(:sys.get_state(ctx.server)) =~ nonce
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          20 -> assert_eventually(fun, tries - 1)
        end
    end
  end
end
