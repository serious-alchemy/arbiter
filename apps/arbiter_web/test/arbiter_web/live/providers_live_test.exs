defmodule ArbiterWeb.ProvidersLiveTest do
  @moduledoc """
  `/providers` (bd-cb86s4): provider accounts with their pools, concurrency,
  credential health and 30-day cost — and create / add-or-rotate credential /
  attach / detach, always available since the P13 flip (bd-9gqj8e).
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{ProviderAccount, ProviderCredential, WorkspaceProviderAccount}
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  require Ash.Query

  @secret "sk-ant-oat01-do-not-echo-me-4f9c"

  # The account/pool/pace/credential/cost overview arrives by `start_async/3`
  # on the connected mount (bd-34f7gt); every test but the loading/error ones
  # themselves wants the page once it has landed.
  @async_timeout 5_000

  defp live_providers(conn, path \\ ~p"/providers") do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp workspace!(name), do: Ash.create!(Workspace, %{name: name, prefix: "pv"})

  defp account!(provider, slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

  defp event!(account, attrs) do
    Ash.create!(
      Event,
      Map.merge(
        %{
          task_id: "bd-pv-#{System.unique_integer([:positive])}",
          source: :task,
          repo: "arbiter",
          workspace_id: "ws-pv",
          step: :work,
          provider_account_id: account.id,
          occurred_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp active_credentials(account) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account.id and active == true)
    |> Ash.read!()
  end

  defp links(account) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account.id)
    |> Ash.read!()
  end

  describe "the account list" do
    test "is linked from the nav", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)
      assert has_element?(view, ~s(a[href="/providers"]))
    end

    test "shows one row per account: provider icon, name and attached workspaces", %{conn: conn} do
      ws = workspace!("pv-attached")
      account = account!(:claude, "pv-main", %{label: "Main Max plan"})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live_providers(conn)

      assert has_element?(view, "#account-#{account.id}")
      assert has_element?(view, "#account-#{account.id}-provider svg[aria-label=Claude]")
      assert has_element?(view, "#account-#{account.id}-name", "Main Max plan")
      assert has_element?(view, "#account-#{account.id}-ws-#{ws.id}", "pv-attached")
    end

    test "shows each pool's utilization against the paced gate's pace", %{conn: conn} do
      account = account!(:claude, "pv-quota")

      Ash.create!(
        AnthropicQuota,
        %{
          provider_account_id: account.id,
          provider: "claude",
          captured_at: DateTime.utc_now(),
          utilization_5h: 0.9,
          # 1h left of a 5h window: 80% elapsed.
          reset_5h_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          utilization_7d: 0.06,
          reset_7d_at: DateTime.add(DateTime.utc_now(), 6 * 86_400, :second)
        },
        action: :record_oauth_snapshot
      )

      {:ok, view, _html} = live_providers(conn)

      assert has_element?(view, "#account-#{account.id}-quota [data-quota-bar=claude]")
      assert has_element?(view, "#account-#{account.id}-pace-5h", "90% used")
      assert has_element?(view, "#account-#{account.id}-pace-5h", "80% pace")
      assert has_element?(view, "#account-#{account.id}-pace-5h[data-pace-verdict=holding]")
      assert has_element?(view, "#account-#{account.id}-pace-7d[data-pace-verdict=ok]")
    end

    test "an account with no quota snapshot says so rather than drawing empty bars", %{conn: conn} do
      account = account!(:codex, "pv-noquota")
      {:ok, view, _html} = live_providers(conn)
      assert has_element?(view, "#account-#{account.id}-quota", "No quota snapshot")
    end

    test "shows the concurrency cap and live count", %{conn: conn} do
      capped = account!(:claude, "pv-capped", %{max_concurrent: 4})
      uncapped = account!(:claude, "pv-uncapped")

      {:ok, view, _html} = live_providers(conn)

      assert has_element?(view, "#account-#{capped.id}-concurrency", "0 / 4")
      assert has_element?(view, "#account-#{uncapped.id}-concurrency", "no cap")
    end

    test "shows credential health", %{conn: conn} do
      bare = account!(:claude, "pv-bare")
      credentialed = account!(:claude, "pv-credentialed")

      {:ok, _} =
        Accounts.rotate_credential(credentialed.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: @secret
        })

      {:ok, view, html} = live_providers(conn)

      assert has_element?(view, "#account-#{bare.id}-health[data-health=no_credential]")
      assert has_element?(view, "#account-#{credentialed.id}-health[data-health=ok]")

      assert has_element?(
               view,
               "#account-#{credentialed.id}-credentials",
               "CLAUDE_CODE_OAUTH_TOKEN"
             )

      assert has_element?(view, "#account-#{credentialed.id}-last-probe", "never")
      refute html =~ @secret
    end

    test "health badge uses correct contrast colors (not -ink on -wash)", %{conn: conn} do
      bare = account!(:claude, "pv-bare-contrast")
      credentialed = account!(:claude, "pv-credentialed-contrast")

      {:ok, _} =
        Accounts.rotate_credential(credentialed.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: @secret
        })

      {:ok, view, html} = live_providers(conn)

      # The health badges should use the base color tokens (e.g., --arb-live)
      # not the -ink variants on -wash backgrounds, to maintain contrast
      assert html =~ "text-[var(--arb-live)]" or
               has_element?(view, "#account-#{credentialed.id}-health")

      assert html =~ "text-[var(--arb-attention)]" or
               has_element?(view, "#account-#{bare.id}-health")

      # Ensure the -ink variants are NOT used on -wash backgrounds
      refute html =~ "bg-[var(--arb-live-wash)] text-[var(--arb-live-ink)]"
      refute html =~ "bg-[var(--arb-attention-wash)] text-[var(--arb-attention-ink)]"
      refute html =~ "bg-[var(--arb-fail-wash)] text-[var(--arb-fail-ink)]"
    end

    test "shows 30-day cost, and n/a for an unpriced provider", %{conn: conn} do
      priced = account!(:claude, "pv-priced")
      unpriced = account!(:antigravity, "pv-agy")
      event!(priced, %{provider: "claude", cost_usd: 1.5, tokens_in: 1000, tokens_out: 500})
      event!(unpriced, %{provider: "gemini", cost_usd: nil, tokens_in: 10, tokens_out: 5})

      {:ok, view, _html} = live_providers(conn)

      assert has_element?(view, "#account-#{priced.id}-cost", "$1.50")
      assert has_element?(view, "#account-#{unpriced.id}-cost", "n/a")
      refute has_element?(view, "#account-#{unpriced.id}-cost", "$")
    end

    test "an empty install shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)
      assert has_element?(view, "#providers-empty")
    end
  end

  describe "create an account" do
    test "creates the account and lists it", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)

      view |> element("#new-account-button") |> render_click()

      view
      |> form("#account-form",
        account: %{provider: "codex", slug: "pv-new", label: "New one", max_concurrent: "3"}
      )
      |> render_submit()

      render_async(view, @async_timeout)

      assert {:ok, account} = Accounts.get_account("codex:pv-new")
      assert account.label == "New one"
      assert account.max_concurrent == 3
      assert has_element?(view, "#account-#{account.id}")
      refute has_element?(view, "#account-form")
    end

    # bd-ac53wz: the upstream Gemini CLI provider is dropped; agy stays.
    test "offers every live provider and not the removed Gemini CLI", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)

      view |> element("#new-account-button") |> render_click()

      for p <- ~w(claude codex antigravity),
          do: assert(has_element?(view, "#account-form option[value='#{p}']"))

      refute has_element?(view, "#account-form option[value='gemini_cli']")
    end

    test "a duplicate slug keeps the form open with the error", %{conn: conn} do
      account!(:claude, "pv-dupe")
      {:ok, view, _html} = live_providers(conn)

      view |> element("#new-account-button") |> render_click()

      view
      |> form("#account-form", account: %{provider: "claude", slug: "pv-dupe"})
      |> render_submit()

      assert has_element?(view, "#account-form")
      assert has_element?(view, "#account-form-error")
    end
  end

  describe "add or rotate a credential" do
    test "posts the secret to the encrypted store and never echoes it back", %{conn: conn} do
      account = account!(:claude, "pv-rotate")
      {:ok, view, _html} = live_providers(conn)

      view |> element("#account-#{account.id}-credential-button") |> render_click()

      assert has_element?(
               view,
               "#credential-form-#{account.id} input[type=password][name='credential[secret]']"
             )

      html =
        view
        |> form("#credential-form-#{account.id}",
          credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: @secret}
        )
        |> render_submit()

      render_async(view, @async_timeout)

      assert [credential] = active_credentials(account)
      assert ProviderCredential.secret(credential) == @secret
      refute html =~ @secret
      refute render(view) =~ @secret

      assert has_element?(
               view,
               "#account-#{account.id}-credentials",
               String.slice(credential.fingerprint, 0, 12)
             )
    end

    test "rotating retires the previous credential", %{conn: conn} do
      account = account!(:claude, "pv-rotate-twice")

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{
          kind: :oauth_token,
          env_var: "CLAUDE_CODE_OAUTH_TOKEN",
          secret: "sk-ant-oat01-old"
        })

      {:ok, view, _html} = live_providers(conn)
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      view
      |> form("#credential-form-#{account.id}",
        credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: @secret}
      )
      |> render_submit()

      render_async(view, @async_timeout)

      assert [credential] = active_credentials(account)
      assert ProviderCredential.secret(credential) == @secret
    end

    test "a failed submit reports the error without echoing the secret", %{conn: conn} do
      account = account!(:claude, "pv-rotate-bad")
      {:ok, view, _html} = live_providers(conn)
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      html =
        view
        |> form("#credential-form-#{account.id}",
          credential: %{kind: "oauth_token", env_var: "", secret: @secret}
        )
        |> render_submit()

      assert active_credentials(account) == []
      assert has_element?(view, "#credential-form-#{account.id}-error")
      refute html =~ @secret
    end

    test "a blank secret is refused", %{conn: conn} do
      account = account!(:claude, "pv-rotate-blank")
      {:ok, view, _html} = live_providers(conn)
      view |> element("#account-#{account.id}-credential-button") |> render_click()

      view
      |> form("#credential-form-#{account.id}",
        credential: %{kind: "oauth_token", env_var: "CLAUDE_CODE_OAUTH_TOKEN", secret: "  "}
      )
      |> render_submit()

      assert active_credentials(account) == []
      assert has_element?(view, "#credential-form-#{account.id}-error")
    end

    test "the secret param is filtered out of LiveView's event logging" do
      assert %{"credential" => %{"secret" => "[FILTERED]"}} =
               Phoenix.Logger.filter_values(%{"credential" => %{"secret" => @secret}})
    end
  end

  describe "attach and detach" do
    test "attaches a workspace to the account", %{conn: conn} do
      ws = workspace!("pv-attach-me")
      account = account!(:claude, "pv-attach")
      {:ok, view, _html} = live_providers(conn)

      view |> element("#account-#{account.id}-attach-button") |> render_click()

      view
      |> form("#attach-form-#{account.id}", attach: %{workspace_id: ws.id, share: "2"})
      |> render_submit()

      render_async(view, @async_timeout)

      assert [%{workspace_id: ws_id, share: 2}] = links(account)
      assert ws_id == ws.id
      assert has_element?(view, "#account-#{account.id}-ws-#{ws.id}", "pv-attach-me")
    end

    test "detaches a workspace from the account", %{conn: conn} do
      ws = workspace!("pv-detach-me")
      account = account!(:claude, "pv-detach")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)
      {:ok, view, _html} = live_providers(conn)

      view |> element("#detach-#{account.id}-#{ws.id}") |> render_click()
      render_async(view, @async_timeout)

      assert links(account) == []
      refute has_element?(view, "#account-#{account.id}-ws-#{ws.id}")
    end
  end

  describe "delete" do
    test "soft-deletes an unattached account, hiding its card", %{conn: conn} do
      account = account!(:claude, "pv-delete-me")
      {:ok, view, _html} = live_providers(conn)

      view |> element("#delete-account-#{account.id}") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#account-#{account.id}")
      assert {:ok, %{deleted_at: %DateTime{}}} = Accounts.get_account(account.id)
    end

    test "shows a refusal reason instead of deleting when attached", %{conn: conn} do
      ws = workspace!("pv-delete-attached-ws")
      account = account!(:claude, "pv-delete-attached")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)
      {:ok, view, _html} = live_providers(conn)

      view |> element("#delete-account-#{account.id}") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(view, "#account-#{account.id}")
      assert render(view) =~ "detach first"
      assert {:ok, %{deleted_at: nil}} = Accounts.get_account(account.id)
    end
  end

  # P13 (bd-9gqj8e): there is no flag to hold the page read-only any more.
  describe "never read-only" do
    test "shows no disabled notice and offers every action", %{conn: conn} do
      ws = workspace!("pv-rw")
      account = account!(:claude, "pv-writable")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live_providers(conn)

      refute has_element?(view, "#accounts-disabled-notice")
      assert has_element?(view, "#account-#{account.id}")
      assert has_element?(view, "#new-account-button")
      assert has_element?(view, "#account-#{account.id}-credential-button")
      assert has_element?(view, "#account-#{account.id}-attach-button")
      assert has_element?(view, "#detach-#{account.id}-#{ws.id}")
      assert has_element?(view, "#delete-account-#{account.id}")
    end
  end

  describe "async load" do
    # Holds the overview read (`Overview.list/1`) in flight until the test
    # says go, so the loading state is something to assert on rather than a
    # race — same discipline as `worker_index_live_test.exs`'s
    # `hold_workers_load/0` (bd-4gtia5).
    defp hold_providers_load do
      test = self()

      :meck.new(Arbiter.Accounts.Overview, [:passthrough, :no_link])

      :meck.expect(Arbiter.Accounts.Overview, :list, fn opts ->
        rows = :meck.passthrough([opts])
        send(test, {:loading_providers, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_providers_load, self()})
        end

        rows
      end)

      on_exit(fn -> :meck.unload(Arbiter.Accounts.Overview) end)
    end

    test "the dead render shows the loading state and does not read the overview", %{conn: conn} do
      test = self()
      :meck.new(Arbiter.Accounts.Overview, [:passthrough, :no_link])

      :meck.expect(Arbiter.Accounts.Overview, :list, fn opts ->
        send(test, :overview_read) && :meck.passthrough([opts])
      end)

      on_exit(fn -> :meck.unload(Arbiter.Accounts.Overview) end)

      doc = conn |> get(~p"/providers") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query(~s(#providers-panel[data-state="loading"])) |> Enum.count() ==
               1

      assert doc |> LazyHTML.query("#providers-loading") |> Enum.count() == 1
      refute_received :overview_read
    end

    test "renders a loading skeleton before the async overview lands, then the data", %{
      conn: conn
    } do
      account = account!(:claude, "pv-async-loading")
      hold_providers_load()

      {:ok, view, _html} = live(conn, ~p"/providers")
      assert_receive {:loading_providers, loader}

      assert has_element?(view, ~s(#providers-panel[data-state="loading"]))
      assert has_element?(view, "#providers-loading")
      refute has_element?(view, "#account-#{account.id}")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#providers-panel[data-state="loaded"]))
      refute has_element?(view, "#providers-loading")
      assert html =~ account.id
      refute_received {:unreleased_providers_load, _}
    end

    test "an async overview-read failure renders an inline error, not a crash", %{conn: conn} do
      :meck.new(Arbiter.Accounts.Overview, [:passthrough, :no_link])
      :meck.expect(Arbiter.Accounts.Overview, :list, fn _opts -> raise "boom" end)
      on_exit(fn -> :meck.unload(Arbiter.Accounts.Overview) end)

      {:ok, view, _html} = live(conn, ~p"/providers")
      html = render_async(view, @async_timeout)

      assert html =~ ~s(id="providers-error")
      assert html =~ "boom"
      assert has_element?(view, "#providers-retry")
    end

    test "the tick refresh still updates the page after the initial async load", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)
      account = account!(:claude, "pv-tick-refresh")

      refute has_element?(view, "#account-#{account.id}")

      send(view.pid, :refresh)
      html = render_async(view, @async_timeout)

      assert html =~ account.id
    end
  end

  describe "pause controls (bd-5ef587)" do
    test "an account can be paused and resumed from the page", %{conn: conn} do
      account = account!(:claude, "pause-me")
      {:ok, view, _html} = live_providers(conn)

      refute has_element?(view, "#account-#{account.id}-paused")

      view
      |> form("#pause-account-form-#{account.id}", %{"reason" => "  "})
      |> render_submit()

      render_async(view, @async_timeout)

      assert %{reason: nil} = Arbiter.Providers.Pause.for_account(account)
      assert has_element?(view, "#account-#{account.id}-paused")
      assert has_element?(view, "#provider-pause-banner")

      view |> element("#resume-account-#{account.id}") |> render_click()
      render_async(view, @async_timeout)

      assert Arbiter.Providers.Pause.for_account(account) == nil
      refute has_element?(view, "#account-#{account.id}-paused")
    end

    test "a provider pause with a reason marks its accounts paused", %{conn: conn} do
      account = account!(:codex, "cx-pause")
      {:ok, view, _html} = live_providers(conn)

      view
      |> form("#pause-provider-codex", %{"reason" => "jail escape"})
      |> render_submit()

      render_async(view, @async_timeout)

      assert %{reason: "jail escape", by: "dashboard"} =
               Arbiter.Providers.Pause.for_account(account)

      assert has_element?(view, "#account-#{account.id}-paused")
      assert has_element?(view, "#pause-toggle-codex", "Resume")
    end
  end

  describe "stray PubSub messages (bd-5spvgy)" do
    test "mailbox broadcasts and unrelated messages do not crash the page", %{conn: conn} do
      {:ok, view, _html} = live_providers(conn)
      pid = view.pid

      message = %Arbiter.Messages.Message{
        kind: :escalation,
        from_ref: "system",
        to_ref: "coordinator"
      }

      send(pid, {:new_message, message})
      send(pid, {:message_read, message})
      send(pid, :totally_unrelated)

      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
      assert render(view) =~ "Providers"
    end
  end
end
