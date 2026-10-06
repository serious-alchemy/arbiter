defmodule ArbiterWeb.ProvidersEditTest do
  @moduledoc """
  The per-account Edit form on `/providers` (bd-8vkqd3): label, plan, enabled,
  the concurrency cap and every settable `quota_config` key, written through
  `Accounts.update_account/2`, `set_max_concurrent/2` and `set_quota_config/2`.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Tasks.Workspace

  @async_timeout 5_000

  defp live_providers(conn) do
    {:ok, view, _html} = live(conn, ~p"/providers")
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp account!(provider, slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: provider, slug: slug}, attrs))

  defp open_edit(view, account),
    do: view |> element("#account-#{account.id}-edit-button") |> render_click()

  defp edit_form(account), do: "#edit-form-#{account.id}"

  describe "opening the form" do
    test "is prefilled from the account and closes on cancel", %{conn: conn} do
      account =
        account!(:claude, "ed-open", %{
          label: "Work Max",
          plan: "max_5x",
          max_concurrent: 3,
          quota_config: %{"threshold_mode" => "paced", "weekly_threshold" => 0.8}
        })

      {:ok, view, _html} = live_providers(conn)
      refute has_element?(view, edit_form(account))

      open_edit(view, account)

      assert has_element?(
               view,
               "#{edit_form(account)} input[name='edit[label]'][value='Work Max']"
             )

      assert has_element?(view, "#{edit_form(account)} input[name='edit[plan]'][value='max_5x']")

      assert has_element?(
               view,
               "#{edit_form(account)} input[name='edit[max_concurrent]'][value='3']"
             )

      assert has_element?(
               view,
               "#{edit_form(account)} select[name='edit[threshold_mode]'] option[value='paced'][selected]"
             )

      assert has_element?(
               view,
               "#{edit_form(account)} input[name='edit[weekly_threshold]'][value='0.8']"
             )

      assert has_element?(view, "#edit-form-#{account.id}-floor-help")

      view |> element("#edit-form-#{account.id}-cancel") |> render_click()
      refute has_element?(view, edit_form(account))
    end

    test "never renders credential material", %{conn: conn} do
      account = account!(:claude, "ed-secret")
      secret = "sk-ant-oat01-edit-form-must-not-echo"

      {:ok, credential} =
        Accounts.rotate_credential(account.id, %{
          "kind" => "oauth_token",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "secret" => secret
        })

      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      html = view |> element(edit_form(account)) |> render()
      refute html =~ secret
      refute html =~ String.slice(credential.fingerprint, 0, 12)
      refute html =~ "CLAUDE_CODE_OAUTH_TOKEN"
      refute has_element?(view, "#{edit_form(account)} input[type=password]")
    end
  end

  describe "saving" do
    test "writes every field and survives a reload", %{conn: conn} do
      account = account!(:claude, "ed-save", %{max_concurrent: 2})
      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      view
      |> form(edit_form(account),
        edit: %{
          label: "Renamed",
          plan: "max_20x",
          enabled: "false",
          max_concurrent: "6",
          threshold_mode: "paced",
          weekly_threshold: "0.75",
          paced_floor: "0.4",
          weekly_paced_floor: "0.25",
          pace_exempt_priority: "1",
          pace_exempt_threshold: "0.95",
          weekly_pace_exempt_threshold: "0.9"
        }
      )
      |> render_submit()

      render_async(view, @async_timeout)
      refute has_element?(view, edit_form(account))

      assert {:ok, saved} = Accounts.get_account(account.id)
      assert saved.label == "Renamed"
      assert saved.plan == "max_20x"
      assert saved.enabled == false
      assert saved.max_concurrent == 6

      assert %{
               "threshold_mode" => "paced",
               "weekly_threshold" => 0.75,
               "paced_floor" => 0.4,
               "weekly_paced_floor" => 0.25,
               "pace_exempt_priority" => 1,
               "pace_exempt_threshold" => 0.95,
               "weekly_pace_exempt_threshold" => 0.9
             } = saved.quota_config

      # A fresh page load shows the saved values in the form.
      {:ok, view, _html} = live_providers(conn)
      assert has_element?(view, "#account-#{account.id}-parked")
      open_edit(view, account)

      assert has_element?(
               view,
               "#{edit_form(account)} input[name='edit[label]'][value='Renamed']"
             )

      assert has_element?(
               view,
               "#{edit_form(account)} input[name='edit[max_concurrent]'][value='6']"
             )

      assert has_element?(
               view,
               "#{edit_form(account)} select[name='edit[pace_exempt_priority]'] option[value='1'][selected]"
             )
    end

    test "a blank cap and blank policy fields clear them, leaving other keys alone", %{conn: conn} do
      account =
        account!(:claude, "ed-clear", %{
          label: "Keep",
          max_concurrent: 4,
          quota_config: %{
            "weekly_threshold" => 0.8,
            "paced_floor" => 0.3,
            "throttle_threshold" => 0.7
          }
        })

      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      view
      |> form(edit_form(account), edit: %{max_concurrent: "", weekly_threshold: ""})
      |> render_submit()

      render_async(view, @async_timeout)

      assert {:ok, saved} = Accounts.get_account(account.id)
      assert saved.max_concurrent == nil
      assert saved.label == "Keep"
      refute Map.has_key?(saved.quota_config, "weekly_threshold")
      assert saved.quota_config["paced_floor"] == 0.3
      assert saved.quota_config["throttle_threshold"] == 0.7
    end

    test "an out-of-range value names the field, keeps the form open and writes nothing",
         %{conn: conn} do
      account = account!(:claude, "ed-invalid", %{label: "Before", max_concurrent: 2})
      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      html =
        view
        |> form(edit_form(account),
          edit: %{label: "After", max_concurrent: "9", weekly_threshold: "1.5"}
        )
        |> render_submit()

      assert has_element?(view, edit_form(account))
      assert has_element?(view, "#edit-form-#{account.id}-error")
      assert view |> element("#edit-form-#{account.id}-error") |> render() =~ "weekly_threshold"
      # What the operator typed is kept for correction.
      assert html =~ "After"

      assert {:ok, unchanged} = Accounts.get_account(account.id)
      assert unchanged.label == "Before"
      assert unchanged.max_concurrent == 2
      assert unchanged.quota_config == %{}
    end

    test "a bad cap is reported against the cap field", %{conn: conn} do
      account = account!(:claude, "ed-badcap")
      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      view
      |> form(edit_form(account), edit: %{max_concurrent: "lots"})
      |> render_submit()

      assert view |> element("#edit-form-#{account.id}-error") |> render() =~ "cap"
      assert {:ok, %{max_concurrent: nil}} = Accounts.get_account(account.id)
    end
  end

  describe "the account value is a floor" do
    test "explains it, and shows the effective value where a workspace also sets one",
         %{conn: conn} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ed-ws",
          prefix: "ed",
          config: %{"quota" => %{"weekly_threshold" => 0.7}}
        })

      account = account!(:claude, "ed-effective", %{quota_config: %{"weekly_threshold" => 0.9}})
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      assert view |> element("#edit-form-#{account.id}-floor-help") |> render() =~ "tighten"
      effective = "#edit-form-#{account.id}-effective-#{ws.id}"
      assert has_element?(view, effective)
      assert view |> element(effective) |> render() =~ "0.7"
      assert view |> element(effective) |> render() =~ "workspace"
    end

    test "a workspace that sets nothing gets no effective line", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "ed-ws-plain", prefix: "ed"})
      account = account!(:claude, "ed-plain")
      {:ok, _} = Accounts.attach_workspace(ws.id, :claude, account.id)

      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      refute has_element?(view, "#edit-form-#{account.id}-effective-#{ws.id}")
    end
  end

  describe "a grok account" do
    test "edits cap, policy, label, plan and enabled, with no routing controls", %{conn: conn} do
      account = account!(:grok, "ed-grok")
      {:ok, view, _html} = live_providers(conn)
      open_edit(view, account)

      assert has_element?(view, "#edit-form-#{account.id}-grok-note")

      for field <- ~w(label plan enabled max_concurrent threshold_mode) do
        assert has_element?(view, "#{edit_form(account)} [name='edit[#{field}]']")
      end

      refute has_element?(view, "#{edit_form(account)} [name*='role']")
      refute has_element?(view, "#{edit_form(account)} [name*='routing']")

      view
      |> form(edit_form(account), edit: %{max_concurrent: "1", label: "Free tier"})
      |> render_submit()

      render_async(view, @async_timeout)

      assert {:ok, %{max_concurrent: 1, label: "Free tier"}} = Accounts.get_account(account.id)
    end
  end
end
