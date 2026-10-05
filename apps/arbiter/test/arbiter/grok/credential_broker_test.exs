defmodule Arbiter.Grok.FakeAdapter do
  @moduledoc false
  # Identity for the auth hold; the broker only needs a module atom.
end

defmodule Arbiter.Grok.CredentialBrokerTest do
  # bd-9p4lx9: single-refresher semantics against a fake OIDC issuer. Every
  # token below is a literal test string; the log assertions check none of
  # them is ever logged.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Grok.CredentialBroker
  alias Arbiter.Grok.CredentialStore

  @entry_key "https://auth.x.ai::client-1"
  @secrets ~w(access-0 refresh-0 access-1 refresh-1 access-2 refresh-2 operator-new-refresh)

  setup context do
    dir = Path.join(System.tmp_dir!(), "gcb-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    stub = :"broker_#{context.test}"

    clock =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> ~U[2030-01-01 00:00:00.000000Z] end}, id: :clock)
      )

    calls = start_supervised!(Supervisor.child_spec({Agent, fn -> [] end}, id: :calls))

    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start:
          {CredentialWatchdog, :start_link,
           [[name: nil, enabled: false, adapters: [Arbiter.Grok.FakeAdapter]]]}
      })

    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    {:ok,
     path: Path.join(dir, "auth.json"), stub: stub, clock: clock, calls: calls, watchdog: watchdog}
  end

  defp now(clock), do: Agent.get(clock, & &1)
  defp advance(clock, seconds), do: Agent.update(clock, &DateTime.add(&1, seconds, :second))

  defp write_auth!(path, overrides \\ %{}) do
    entry =
      Map.merge(
        %{
          "key" => "access-0",
          "auth_mode" => "oidc",
          "refresh_token" => "refresh-0",
          "expires_at" => "2030-01-01T06:00:00.000000000Z",
          "oidc_issuer" => "https://auth.x.ai",
          "oidc_client_id" => "client-1"
        },
        overrides
      )

    File.write!(path, Jason.encode!(%{@entry_key => entry}))
    File.chmod!(path, 0o600)
  end

  # The fake issuer: counts every refresh grant, answers with a numbered token
  # pair, and (optionally) holds each grant for `delay` ms so concurrent callers
  # genuinely overlap.
  defp stub_issuer(ctx, opts \\ []) do
    delay = Keyword.get(opts, :delay, 0)
    responder = Keyword.get(opts, :responder)

    Req.Test.stub(ctx.stub, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{"token_endpoint" => "https://auth.x.ai/oauth2/token"})

        "/oauth2/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          grant = URI.decode_query(body)
          n = Agent.get_and_update(ctx.calls, fn l -> {length(l) + 1, [grant | l]} end)
          if delay > 0, do: Process.sleep(delay)

          if responder do
            responder.(conn, n, grant)
          else
            Req.Test.json(conn, %{
              "access_token" => "access-#{n}",
              "refresh_token" => "refresh-#{n}",
              "expires_in" => 21_600
            })
          end
      end
    end)
  end

  defp grants(ctx), do: ctx.calls |> Agent.get(& &1) |> Enum.reverse()

  defp start_broker(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          auth_path: ctx.path,
          now_fun: fn -> now(ctx.clock) end,
          req_options: [plug: {Req.Test, ctx.stub}],
          credential_watchdog: ctx.watchdog,
          hold_adapter: Arbiter.Grok.FakeAdapter
        ],
        opts
      )

    {:ok, pid} =
      start_supervised(%{id: make_ref(), start: {CredentialBroker, :start_link, [opts]}})

    # The refresh runs in a task the broker spawns; stubs resolve through
    # `$callers`, but the shared mode keeps it independent of that.
    Req.Test.set_req_test_to_shared(%{async: false})
    pid
  end

  defp assert_no_secret_in(log) do
    for secret <- @secrets, do: refute(log =~ secret, "log leaked #{secret}")
  end

  describe "serving a token" do
    test "a still-fresh token is served from the canonical file with no refresh", ctx do
      write_auth!(ctx.path)
      stub_issuer(ctx)
      broker = start_broker(ctx)

      assert {:ok, %{access_token: "access-0", expires_in: expires_in}} =
               CredentialBroker.fetch_token([], broker)

      assert expires_in == 21_600
      assert grants(ctx) == []
    end

    test "the reply carries no refresh token", ctx do
      write_auth!(ctx.path)
      broker = start_broker(ctx)

      {:ok, reply} = CredentialBroker.fetch_token([], broker)
      assert Map.keys(reply) |> Enum.sort() == [:access_token, :expires_in]
    end

    test "a token inside the refresh margin is refreshed once and persisted", ctx do
      write_auth!(ctx.path)
      stub_issuer(ctx)
      broker = start_broker(ctx)

      # 6h token, 10 minute margin: step to 5 minutes before expiry.
      advance(ctx.clock, 6 * 3600 - 300)

      assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
      assert [%{"refresh_token" => "refresh-0", "grant_type" => "refresh_token"}] = grants(ctx)

      # The rotated pair is the canonical one now.
      assert {:ok, canonical} = CredentialStore.read(ctx.path)
      assert canonical.access_token == "access-1"
      assert canonical.refresh_token == "refresh-1"

      # And the next worker is served from it without another refresh.
      assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
      assert length(grants(ctx)) == 1
    end

    test "a worker whose token expires mid-run is handed a fresh one", ctx do
      write_auth!(ctx.path)
      stub_issuer(ctx)
      broker = start_broker(ctx)

      assert {:ok, %{access_token: "access-0"}} = CredentialBroker.fetch_token([], broker)
      assert grants(ctx) == []

      # grok re-runs the provider command ~5 min before expiry (GROK_AUTH_EXPIRED=1).
      advance(ctx.clock, 6 * 3600 - 240)

      assert {:ok, %{access_token: "access-1", expires_in: 21_600}} =
               CredentialBroker.fetch_token([force: true], broker)

      assert length(grants(ctx)) == 1
    end
  end

  describe "single writer" do
    test "concurrent workers needing a fresh token trigger exactly one refresh", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})
      stub_issuer(ctx, delay: 150)
      broker = start_broker(ctx)

      replies =
        1..25
        |> Task.async_stream(fn _ -> CredentialBroker.fetch_token([force: true], broker) end,
          max_concurrency: 25,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, reply} -> reply end)

      assert length(replies) == 25
      assert Enum.all?(replies, &match?({:ok, %{access_token: "access-1"}}, &1))
      assert length(grants(ctx)) == 1

      assert {:ok, canonical} = CredentialStore.read(ctx.path)
      assert canonical.refresh_token == "refresh-1"
    end

    test "a forced re-request right after a refresh does not refresh again", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})
      stub_issuer(ctx)
      broker = start_broker(ctx)

      assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
      advance(ctx.clock, 5)

      # A second worker's 401 retry arrives seconds later.
      assert {:ok, %{access_token: "access-1"}} =
               CredentialBroker.fetch_token([force: true], broker)

      assert length(grants(ctx)) == 1

      # Once the coalescing window has passed a forced request refreshes again.
      advance(ctx.clock, 120)

      assert {:ok, %{access_token: "access-2"}} =
               CredentialBroker.fetch_token([force: true], broker)

      assert length(grants(ctx)) == 2
    end

    @tag :posix_perms
    test "a refresh that cannot be written is kept in memory and retried", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})
      stub_issuer(ctx)
      broker = start_broker(ctx)
      dir = Path.dirname(ctx.path)

      # A read-only directory takes the temp file for the write-back, but the
      # file stays readable.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod!(dir, 0o700) end)

      if File.touch(Path.join(dir, "probe")) == :ok do
        # Running as a user the mode does not bind (root): nothing to prove.
        File.rm!(Path.join(dir, "probe"))
      else
        log =
          capture_log(fn ->
            assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
          end)

        assert_no_secret_in(log)
        assert log =~ "could not write"

        # Still the old pair on disk, but served from memory: no second grant.
        assert {:ok, on_disk} = CredentialStore.read(ctx.path)
        assert on_disk.refresh_token == "refresh-0"
        assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
        assert length(grants(ctx)) == 1

        # The directory heals; the next request writes the rotated pair through.
        File.chmod!(dir, 0o700)
        assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
        assert {:ok, on_disk} = CredentialStore.read(ctx.path)
        assert on_disk.refresh_token == "refresh-1"
        assert length(grants(ctx)) == 1
      end
    end
  end

  describe "permanent refresh failure" do
    defp invalid_grant(conn, _n, _grant) do
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_grant", "error_description" => "Invalid or unknown"})
    end

    test "raises an auth hold, keeps the canonical file, fails workers fast", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})
      before = File.read!(ctx.path)
      stub_issuer(ctx, responder: &invalid_grant/3)
      broker = start_broker(ctx)

      log =
        capture_log(fn ->
          assert {:error, :reauth_required} = CredentialBroker.fetch_token([], broker)
        end)

      assert_no_secret_in(log)
      assert log =~ "re-login"

      # The hold is the dispatch gate: no further grok workers start.
      assert CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
      assert %{reauth_required?: true} = CredentialBroker.status(broker)

      # The canonical file is untouched, not deleted.
      assert File.read!(ctx.path) == before

      # Every later worker is refused immediately: no more grants at the issuer
      # (a doomed refresh would just burn the call).
      assert {:error, :reauth_required} = CredentialBroker.fetch_token([], broker)
      assert {:error, :reauth_required} = CredentialBroker.fetch_token([force: true], broker)
      assert length(grants(ctx)) == 1
    end

    test "concurrent workers all get :reauth_required from the one failed refresh", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})

      stub_issuer(ctx, delay: 100, responder: &invalid_grant/3)
      broker = start_broker(ctx)

      replies =
        1..10
        |> Task.async_stream(fn _ -> CredentialBroker.fetch_token([], broker) end,
          max_concurrency: 10,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(replies, &(&1 == {:error, :reauth_required}))
      assert length(grants(ctx)) == 1

      # The hold is raised by a cast; let the watchdog finish its alert write
      # before the sandbox goes away.
      assert CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
    end

    test "an operator re-login clears the hold and serving resumes", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})
      stub_issuer(ctx, responder: &invalid_grant/3)
      broker = start_broker(ctx)

      assert {:error, :reauth_required} = CredentialBroker.fetch_token([], broker)
      assert CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)

      # `grok login` writes a new credential into the canonical file.
      write_auth!(ctx.path, %{
        "key" => "access-1",
        "refresh_token" => "operator-new-refresh",
        "expires_at" => "2030-01-01T06:00:00.000000000Z"
      })

      assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
      refute CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
      assert %{reauth_required?: false} = CredentialBroker.status(broker)
    end

    test "invalid_grant after someone else rotated the file retries with the new token", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})

      # The operator's own interactive grok refreshes the canonical file while
      # our grant is in flight; our (now stale) refresh token is then refused.
      responder = fn conn, n, grant ->
        if grant["refresh_token"] == "refresh-0" do
          write_auth!(ctx.path, %{
            "key" => "access-1",
            "refresh_token" => "operator-new-refresh",
            "expires_at" => "2030-01-01T06:00:00.000000000Z"
          })

          invalid_grant(conn, n, grant)
        else
          Req.Test.json(conn, %{
            "access_token" => "access-2",
            "refresh_token" => "refresh-2",
            "expires_in" => 21_600
          })
        end
      end

      stub_issuer(ctx, responder: responder)
      broker = start_broker(ctx)

      # The operator's rewrite already carries a fresh token, so the retry
      # adopts it rather than spending another grant.
      assert {:ok, %{access_token: "access-1"}} = CredentialBroker.fetch_token([], broker)
      refute CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
      assert length(grants(ctx)) == 1
    end

    test "a missing canonical file raises the hold; nothing is created", ctx do
      stub_issuer(ctx)
      broker = start_broker(ctx)

      assert {:error, :not_logged_in} = CredentialBroker.fetch_token([], broker)
      assert CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
      refute File.exists?(ctx.path)
      assert grants(ctx) == []
    end
  end

  describe "transient refresh failure" do
    test "serves the still-valid token and raises no hold", ctx do
      # Inside the refresh margin but not yet expired.
      write_auth!(ctx.path, %{"expires_at" => "2030-01-01T00:05:00.000000000Z"})

      stub_issuer(ctx,
        responder: fn conn, _n, _g -> Plug.Conn.send_resp(conn, 503, "overloaded") end
      )

      broker = start_broker(ctx)

      assert {:ok, %{access_token: "access-0", expires_in: 300}} =
               CredentialBroker.fetch_token([], broker)

      refute CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
    end

    test "an already-expired token with the issuer down is :unavailable, not a hold", ctx do
      write_auth!(ctx.path, %{"expires_at" => "2029-12-31T00:00:00.000000000Z"})

      stub_issuer(ctx,
        responder: fn conn, _n, _g -> Plug.Conn.send_resp(conn, 503, "overloaded") end
      )

      broker = start_broker(ctx)

      assert {:error, :unavailable} = CredentialBroker.fetch_token([], broker)
      refute CredentialWatchdog.expired?(Arbiter.Grok.FakeAdapter, ctx.watchdog)
      assert %{reauth_required?: false} = CredentialBroker.status(broker)
    end
  end
end
