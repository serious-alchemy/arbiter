defmodule Arbiter.Quota.ControlChannelUsageTest do
  @moduledoc """
  bd-a2zrh0: `Arbiter.Quota.capture_oauth_usage/2` reads usage over the Claude
  control channel (`get_usage`) when it can, and uses the HTTP `/api/oauth/usage`
  poll — exactly as before — whenever the channel cannot answer.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Agents.Claude.ControlChannel
  alias Arbiter.Quota
  alias Arbiter.Test.ClaudeControlStub

  @moduletag :capture_log
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} = context do
    Application.put_env(:arbiter, :oauth_usage_http_stub, true)
    Application.put_env(:arbiter, ControlChannel, enabled: true)
    Req.Test.set_req_test_to_shared(context)

    on_exit(fn -> Application.put_env(:arbiter, ControlChannel, enabled: false) end)

    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "control-usage"})

    grant_dir = Path.join(tmp_dir, "quota-claude")
    File.mkdir_p!(grant_dir)

    File.write!(
      Path.join(grant_dir, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "grant-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{kind: :cli_credentials_path, secret: grant_dir})

    on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!(account.id) end)

    test_pid = self()

    Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
      send(test_pid, {:http_usage, Plug.Conn.get_req_header(conn, "authorization")})
      Req.Test.json(conn, %{"five_hour" => %{"utilization" => 77}})
    end)

    # A wrapper that records the config dir the CLI is pointed at, then runs
    # the stub CLI.
    stub = ClaudeControlStub.write!(tmp_dir)
    seen = Path.join(tmp_dir, "config-dir-seen")
    wrapper = Path.join(tmp_dir, "wrap.sh")
    File.write!(wrapper, ~s(#!/bin/sh\necho "$CLAUDE_CONFIG_DIR" > #{seen}\nexec sh "$@"\n))

    %{account: account, grant_dir: grant_dir, stub: stub, wrapper: wrapper, seen: seen}
  end

  defp capture(ctx, mode, extra \\ []) do
    Quota.capture_oauth_usage(
      ctx.account.id,
      control_channel:
        [control_command: ["sh", ctx.wrapper, ctx.stub, mode], timeout_ms: 2_000] ++ extra
    )
  end

  test "usage is read from get_usage, in the grant config dir, with no HTTP call", ctx do
    assert {:ok, snapshot} = capture(ctx, "ok")

    # The stub's five_hour utilization is 42.0 (a 0-100 percentage).
    assert_in_delta snapshot.utilization_5h, 0.42, 0.001
    refute_received {:http_usage, _}
    assert ctx.seen |> File.read!() |> String.trim() == ctx.grant_dir
  end

  for mode <- ~w(no_usage init_unsupported exit usage_empty usage_429 usage_hang) do
    test "control channel answering #{mode} falls back to the HTTP poll", ctx do
      assert {:ok, snapshot} = capture(ctx, unquote(mode), timeout_ms: 300)

      assert_received {:http_usage, ["Bearer grant-token"]}
      # The HTTP stub's five_hour utilization is 77, not the control stub's 42.
      assert_in_delta snapshot.utilization_5h, 0.77, 0.001
    end
  end

  test "a disabled channel is never spawned", ctx do
    Application.put_env(:arbiter, ControlChannel, enabled: false)
    assert {:ok, snapshot} = capture(ctx, "ok")
    assert_in_delta snapshot.utilization_5h, 0.77, 0.001
    refute File.exists?(ctx.seen)
  end
end
