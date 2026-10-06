defmodule ArbiterWeb.WorkspaceProviderSettingsLiveTest do
  @moduledoc """
  bd-64apru: the workspace page's Providers section — allowed accounts per
  role, preference order, concurrency share, and the effective resolved
  setting with its config fallback.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts.{ProviderAccount, ProviderSettings, WorkspaceProviderAccount}
  alias Arbiter.Tasks.Workspace

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "wps-#{System.unique_integer([:positive])}",
      prefix: "wp",
      config: config
    })
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp click(view, event, role, account) do
    view
    |> element(
      ~s(button[phx-click=#{event}][phx-value-role=#{role}][phx-value-account="#{account.id}"])
    )
    |> render_click()
  end

  defp open(conn, ws) do
    {:ok, view, _html} = live_workspace(conn, ws.id)
    view |> element(~s(#ws-rail button[phx-value-section=providers])) |> render_click()
    view
  end

  defp source(view, role) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#provider-effective-#{role}")
    |> LazyHTML.attribute("data-source")
    |> List.first()
  end

  test "the rail has a Providers section", %{conn: conn} do
    view = open(conn, workspace!())

    assert has_element?(
             view,
             ~s(#ws-rail button[phx-value-section=providers][aria-selected=true])
           )

    assert has_element?(view, "#provider-settings")
  end

  # bd-i2gwwn: `/usage`'s "No providers configured" empty state links here.
  test "?section=providers opens straight on the Providers section", %{conn: conn} do
    ws = workspace!()
    {:ok, view, _html} = live(conn, "/workspaces/#{ws.id}?section=providers")
    render_async(view)

    assert has_element?(
             view,
             ~s(#ws-rail button[phx-value-section=providers][aria-selected=true])
           )

    {:ok, view, _html} = live(conn, "/workspaces/#{ws.id}?section=bogus")
    render_async(view)
    assert has_element?(view, ~s(#ws-rail button[phx-value-section=repos][aria-selected=true]))
  end

  test "with nothing attached, shows the config fallback as the effective setting", %{conn: conn} do
    ws = workspace!(%{"agent" => %{"type" => ["codex", "claude"]}})
    view = open(conn, ws)

    assert source(view, "implementer") == "agent_type"
    assert source(view, "reviewer") == "implementer"

    assert has_element?(view, "#provider-effective-implementer [data-candidate=codex]")
    assert has_element?(view, "#provider-effective-implementer [data-candidate=claude]")

    # The fallback editor is the old agent.type precedence list.
    assert has_element?(view, ~s(button[phx-click=remove_agent_type][phx-value-role=agent]))
  end

  test "adds an account to a role, persists it and projects agent.type", %{conn: conn} do
    ws = workspace!()
    codex = account!(:codex, "wps-codex")
    view = open(conn, ws)

    click(view, "add_role_account", "implementer", codex)

    assert has_element?(view, "#provider-role-implementer-#{codex.id}")
    assert source(view, "implementer") == "attached"

    reloaded = Ash.get!(Workspace, ws.id)
    assert reloaded.config["agent"]["type"] == "codex"
    assert ProviderSettings.effective(reloaded, :implementer).source == :attached

    # agent.type is now written from the list, so its hand editor is gone.
    refute has_element?(view, ~s(button[phx-click=add_agent_type][phx-value-role=agent]))
  end

  test "reorders and removes accounts in a role", %{conn: conn} do
    ws = workspace!()
    codex = account!(:codex, "wps-mv-codex")
    claude = account!(:claude, "wps-mv-claude")
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, codex.id)
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, claude.id)
    view = open(conn, ws)

    view
    |> element(
      ~s(button[phx-click=move_role_account][phx-value-role=reviewer][phx-value-account="#{claude.id}"][phx-value-dir=up])
    )
    |> render_click()

    assert Ash.get!(Workspace, ws.id).config["review_agent"]["type"] == ["claude", "codex"]

    click(view, "remove_role_account", "reviewer", claude)

    refute has_element?(view, "#provider-role-reviewer-#{claude.id}")
    assert Ash.get!(Workspace, ws.id).config["review_agent"]["type"] == "codex"
  end

  test "explains why a second account for a used provider is refused", %{conn: conn} do
    ws = workspace!()
    a = account!(:claude, "wps-taken-a")
    b = account!(:claude, "wps-taken-b")
    {:ok, ws} = ProviderSettings.add(ws, :reviewer, a.id)
    view = open(conn, ws)

    click(view, "add_role_account", "implementer", b)

    assert has_element?(view, "#provider-settings-error", "wps-taken-a")
    refute has_element?(view, "#provider-role-implementer-#{b.id}")
  end

  test "sets and clears the workspace's concurrency share of an account", %{conn: conn} do
    ws = workspace!()
    acct = account!(:claude, "wps-share", %{max_concurrent: 4})
    {:ok, ws} = ProviderSettings.add(ws, :implementer, acct.id)
    view = open(conn, ws)

    view |> form("#share-form-#{acct.id}", %{"share" => "2"}) |> render_submit()

    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == 2
    assert has_element?(view, "#share-cap-#{acct.id}", "2")

    view |> form("#share-form-#{acct.id}", %{"share" => ""}) |> render_submit()
    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == nil

    view |> form("#share-form-#{acct.id}", %{"share" => "-3"}) |> render_submit()
    assert has_element?(view, "#provider-settings-error")
    assert Arbiter.Accounts.Resolver.share(ws.id, :claude) == nil
  end

  test "adopts the accounts the fallback already resolves to", %{conn: conn} do
    ws = workspace!(%{"agent" => %{"type" => "claude"}})
    acct = account!(:claude, "wps-adopt")
    link!(ws, acct)
    view = open(conn, ws)

    view |> element("#adopt-implementer") |> render_click()

    assert source(view, "implementer") == "attached"
    assert has_element?(view, "#provider-role-implementer-#{acct.id}")
  end

  test "offers no adopt action when no fallback type has an account", %{conn: conn} do
    view = open(conn, workspace!(%{"agent" => %{"type" => "claude"}}))

    refute has_element?(view, "#adopt-implementer")
  end

  describe "routing strategy (bd-adlvm6)" do
    defp strategy(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#routing-strategy-form input[type=radio][checked]")
      |> LazyHTML.attribute("value")
      |> List.first()
    end

    test "defaults to failover; selecting most_quota persists routing.provider_selection", %{
      conn: conn
    } do
      ws = workspace!()
      view = open(conn, ws)

      assert strategy(view) == "failover"
      assert has_element?(view, "#routing-help-failover", "healthy")
      assert has_element?(view, "#routing-help-most_quota")
      refute has_element?(view, "#routing-ranking")

      view
      |> form("#routing-strategy-form", %{"provider_selection" => "most_quota"})
      |> render_change()

      assert Ash.get!(Workspace, ws.id).config["routing"]["provider_selection"] == "most_quota"
      assert strategy(view) == "most_quota"
      assert has_element?(view, "#routing-ranking")

      view
      |> form("#routing-strategy-form", %{"provider_selection" => "failover"})
      |> render_change()

      assert get_in(Ash.get!(Workspace, ws.id).config, ["routing", "provider_selection"]) in [
               nil,
               "failover"
             ]

      refute has_element?(view, "#routing-ranking")
    end

    test "states the reviewer's selection behaviour", %{conn: conn} do
      ws = workspace!()
      view = open(conn, ws)
      assert has_element?(view, "#routing-reviewer-note")
      assert has_element?(view, "#routing-reviewer-note", "own order")
      refute has_element?(view, "#routing-reviewer-note", "headroom")

      ws2 = workspace!(%{"review_agent" => %{"cross_family" => true}})
      view2 = open(conn, ws2)
      assert has_element?(view2, "#routing-reviewer-note", "headroom")
      refute has_element?(view2, "#routing-reviewer-note", "own order")
      refute has_element?(view2, "#routing-reviewer-note", "never most_quota")
    end

    test "lists each implementer candidate's headroom or drop reason" do
      ws =
        workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})

      held = account!(:claude, "held")
      free = account!(:codex, "free")
      link!(ws, held, %{implementer_position: 1})
      link!(ws, free, %{implementer_position: 2})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      quota = fn
        %{id: id} when id == held.id ->
          %Arbiter.Quota.AnthropicQuota{
            provider: "claude",
            utilization_5h: 0.99,
            reset_5h_at: DateTime.add(now, 9_000),
            status_5h: "allowed",
            utilization_7d: 0.0,
            reset_7d_at: DateTime.add(now, 302_400),
            status_7d: "allowed",
            captured_at: now
          }

        _ ->
          %Arbiter.Quota.CodexQuota{
            provider: "codex",
            session_used_percent: 1.0,
            session_reset_at: DateTime.add(now, 3_600),
            weekly_used_percent: 0.0,
            weekly_reset_at: DateTime.add(now, 302_400),
            limit_reached: false,
            captured_at: now
          }
      end

      html =
        render_component(ArbiterWeb.WorkspaceDetail.ProviderSettingsComponent,
          id: "provider-settings-section",
          section: "providers",
          workspace: Ash.get!(Workspace, ws.id),
          agent_types: ["claude", "codex"],
          routing_opts: [quota_fun: quota]
        )

      doc = LazyHTML.from_fragment(html)

      assert Enum.count(
               LazyHTML.query(
                 doc,
                 ~s(#routing-ranking [data-account="#{free.id}"][data-status=available])
               )
             ) == 1

      assert Enum.count(
               LazyHTML.query(
                 doc,
                 ~s(#routing-ranking [data-account="#{held.id}"][data-status=quota_held])
               )
             ) == 1
    end
  end

  describe "scoring (bd-8vkqd3)" do
    defp config_of(ws), do: Ash.get!(Workspace, ws.id).config

    defp scoring_mode(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#scoring-form input[type=radio][checked]")
      |> LazyHTML.attribute("value")
      |> List.first()
    end

    test "defaults to off and hides the competence switch", %{conn: conn} do
      view = open(conn, workspace!())

      assert has_element?(view, "#scoring-form")
      assert scoring_mode(view) == "off"
      refute has_element?(view, "#scoring-competence")
    end

    test "shadow then enforce persist routing.scoring.mode and select the scored strategy",
         %{conn: conn} do
      ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})
      view = open(conn, ws)

      view |> form("#scoring-form", %{"scoring_mode" => "shadow"}) |> render_change()
      config = config_of(ws)
      assert get_in(config, ["routing", "provider_selection"]) == "scored"
      assert get_in(config, ["routing", "scoring", "mode"]) == "shadow"
      assert scoring_mode(view) == "shadow"
      assert has_element?(view, "#scoring-competence")

      view |> form("#scoring-form", %{"scoring_mode" => "enforce"}) |> render_change()
      assert get_in(config_of(ws), ["routing", "scoring", "mode"]) == "enforce"
      assert scoring_mode(view) == "enforce"
    end

    test "competence is written as true and unset (not false) when cleared", %{conn: conn} do
      ws =
        workspace!(%{
          "routing" => %{
            "provider_selection" => "scored",
            "scoring" => %{"mode" => "shadow", "time_weight" => %{"P0" => 2}}
          }
        })

      view = open(conn, ws)

      view
      |> form("#scoring-form", %{"scoring_mode" => "shadow", "competence" => "true"})
      |> render_change()

      assert get_in(config_of(ws), ["routing", "scoring", "competence"]) == true

      view
      |> form("#scoring-form", %{"scoring_mode" => "shadow", "competence" => "false"})
      |> render_change()

      scoring = get_in(config_of(ws), ["routing", "scoring"])
      refute Map.has_key?(scoring, "competence")
      # Sibling scoring keys are left alone.
      assert scoring["time_weight"] == %{"P0" => 2}
    end

    test "off unsets the mode and drops back to most_quota, not failover", %{conn: conn} do
      ws =
        workspace!(%{
          "routing" => %{
            "provider_selection" => "scored",
            "scoring" => %{"mode" => "enforce"}
          }
        })

      view = open(conn, ws)
      assert scoring_mode(view) == "enforce"

      view |> form("#scoring-form", %{"scoring_mode" => "off"}) |> render_change()

      config = config_of(ws)
      assert get_in(config, ["routing", "provider_selection"]) == "most_quota"
      refute Map.has_key?(get_in(config, ["routing", "scoring"]) || %{}, "mode")
      assert scoring_mode(view) == "off"
    end

    test "a rejected write shows the error and leaves the config alone", %{conn: conn} do
      ws = workspace!()
      view = open(conn, ws)

      view |> element("#scoring-form") |> render_change(%{"scoring_mode" => "turbo"})

      assert get_in(config_of(ws), ["routing", "scoring"]) == nil
      assert has_element?(view, "#provider-settings-error")
    end
  end

  describe "workspace pace exemption (bd-8vkqd3)" do
    defp exempt_value(view) do
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#pace-exempt-form select option[selected]")
      |> LazyHTML.attribute("value")
      |> List.first()
    end

    test "narrowing is written as an integer, 'none', or unset when blank", %{conn: conn} do
      ws = workspace!(%{"quota" => %{"throttle_threshold" => 0.8}})
      view = open(conn, ws)

      assert has_element?(view, "#pace-exempt-form")
      assert exempt_value(view) in [nil, ""]

      view |> form("#pace-exempt-form", %{"pace_exempt_priority" => "1"}) |> render_change()
      assert get_in(config_of(ws), ["quota", "pace_exempt_priority"]) == 1
      assert exempt_value(view) == "1"

      view |> form("#pace-exempt-form", %{"pace_exempt_priority" => "none"}) |> render_change()
      assert get_in(config_of(ws), ["quota", "pace_exempt_priority"]) == "none"

      view |> form("#pace-exempt-form", %{"pace_exempt_priority" => ""}) |> render_change()
      quota = get_in(config_of(ws), ["quota"])
      refute Map.has_key?(quota, "pace_exempt_priority")
      assert quota["throttle_threshold"] == 0.8
    end

    test "shows what each attached account actually ends up with", %{conn: conn} do
      ws = workspace!(%{"quota" => %{"pace_exempt_priority" => 1}})
      granting = account!(:claude, "wps-grants", %{quota_config: %{"pace_exempt_priority" => 3}})
      silent = account!(:codex, "wps-silent")
      link!(ws, granting)
      link!(ws, silent)

      view = open(conn, ws)

      assert view |> element("#pace-exempt-effective-#{granting.id}") |> render() =~ "P0 to P1"
      assert view |> element("#pace-exempt-effective-#{silent.id}") |> render() =~ "off"
    end
  end

  describe "grok routing (bd-co08p2)" do
    test "the toggle sets and clears routing.grok.enabled, keeping other config", %{conn: conn} do
      ws = workspace!(%{"routing" => %{"provider_selection" => "most_quota"}})
      view = open(conn, ws)

      assert has_element?(view, "#grok-routing-form")
      assert has_element?(view, "#grok-auth-state")
      refute has_element?(view, ~s(#grok-routing-form input[type=checkbox][checked]))
      refute has_element?(view, "#grok-difficulties")

      view |> form("#grok-routing-form", %{"enabled" => "true"}) |> render_change()

      config = Ash.get!(Workspace, ws.id).config
      assert get_in(config, ["routing", "grok", "enabled"]) == true
      assert get_in(config, ["routing", "provider_selection"]) == "most_quota"
      assert has_element?(view, "#grok-difficulties")

      view |> form("#grok-routing-form", %{"enabled" => "false"}) |> render_change()

      config = Ash.get!(Workspace, ws.id).config
      assert get_in(config, ["routing", "grok", "enabled"]) in [nil, false]
      assert get_in(config, ["routing", "provider_selection"]) == "most_quota"
    end

    test "the difficulties list is written and a blank list clears it", %{conn: conn} do
      ws = workspace!(%{"routing" => %{"grok" => %{"enabled" => true}}})
      view = open(conn, ws)

      view
      |> form("#grok-routing-form", %{"enabled" => "true", "difficulties" => "1, 2"})
      |> render_change()

      config = Ash.get!(Workspace, ws.id).config
      assert get_in(config, ["routing", "grok", "difficulties"]) == [1, 2]

      view
      |> form("#grok-routing-form", %{"enabled" => "true", "difficulties" => "9"})
      |> render_change()

      assert has_element?(view, "#provider-settings-error")

      view
      |> form("#grok-routing-form", %{"enabled" => "true", "difficulties" => ""})
      |> render_change()

      config = Ash.get!(Workspace, ws.id).config
      assert get_in(config, ["routing", "grok", "difficulties"]) == nil
      assert get_in(config, ["routing", "grok", "enabled"]) == true
    end

    test "the pane points to the Providers page", %{conn: conn} do
      view = open(conn, workspace!())
      assert has_element?(view, ~s(#provider-settings-help a[href="/providers"]))
    end
  end
end
