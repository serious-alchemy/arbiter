defmodule Arbiter.Quota.StalenessWatchTest do
  @moduledoc """
  `Arbiter.Quota.StalenessWatch` (bd-2wnkoq): an operator alert keyed on the
  Claude quota snapshot's *state* — how old it is — raised on the watch's own
  timer, never from `Arbiter.Quota.CloudProbe`'s poll/failure path.

  The incident behind it: one expired token left the gate on a snapshot
  nineteen hours old. The 5h gate and 5h overage detection failed open the
  whole time, and nothing alerted, because every quota alarm was raised by a
  component reporting a failure, and the component had stopped reporting.
  """
  use Arbiter.DataCase, async: false

  # Every stale check logs a warning by design.
  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Alerts
  alias Arbiter.Alerts.SystemAlert
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CloudProbe
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.StalenessWatch
  alias Arbiter.Tasks.Workspace

  @quota_keys [
    :stale_alert_threshold_seconds,
    :staleness_threshold_seconds,
    :polled_staleness_threshold_seconds,
    :weekly_threshold,
    :weekly_warning_policy,
    :gate
  ]

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      prior |> Keyword.drop(@quota_keys) |> Keyword.put(:on_exhaustion, :throttle)
    )

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp workspace!(name \\ nil), do: Ash.create!(Workspace, %{name: name || "sw-#{uniq()}"})

  defp account!(slug \\ nil) do
    Ash.create!(ProviderAccount, %{
      provider: :claude,
      slug: slug || "sw-#{uniq()}",
      label: "staleness watch"
    })
  end

  defp link!(%Workspace{} = ws, %ProviderAccount{} = account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })
  end

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp ahead(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  # Lands (or replaces — the table holds one row per account) the account's
  # Claude snapshot, the way a poll writes it.
  defp snapshot!(%ProviderAccount{} = account, attrs) do
    Ash.create!(
      AnthropicQuota,
      Map.merge(
        %{
          provider_account_id: account.id,
          provider: "claude",
          capture_source: "oauth_poll",
          captured_at: ago(60),
          utilization_5h: 0.30,
          status_5h: "allowed",
          reset_5h_at: ahead(3_600),
          utilization_7d: 0.40,
          status_7d: "allowed",
          reset_7d_at: ahead(3 * 86_400)
        },
        attrs
      )
    )
  end

  # The observed incident: a workspace on one Claude account whose snapshot
  # stopped moving nineteen hours ago.
  defp blind_install!(attrs \\ %{}) do
    ws = workspace!()
    account = account!()
    link!(ws, account)
    quota = snapshot!(account, Map.merge(%{captured_at: ago(19 * 3_600)}, attrs))
    %{ws: ws, account: account, quota: quota}
  end

  defp start_watch(opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          enabled: true,
          initial_delay_ms: :timer.hours(1),
          interval_ms: :timer.hours(1)
        ],
        opts
      )

    start_supervised!(Supervisor.child_spec({StalenessWatch, opts}, id: make_ref()))
  end

  defp stale_alerts, do: Alerts.active(kind: :quota_snapshot_stale)

  describe "a stale snapshot (AC 1, AC 3)" do
    test "raises the alert from the snapshot alone — CloudProbe never polled, never reported a failure" do
      %{ws: ws, account: account} = blind_install!()

      # The application's CloudProbe is switched off under test: it has never
      # polled, so nothing anywhere is reporting a poll failure.
      assert %{enabled: false, probe_count: 0, oauth_consecutive_failures: 0} = CloudProbe.state()
      assert Alerts.active(kind: :quota_poll_failing) == []

      pid = start_watch()
      assert {:ok, _results} = StalenessWatch.check_now(pid)

      assert [alert] = stale_alerts()
      assert alert.key == "claude:#{account.id}"
      assert alert.workspace_id == ws.id
      assert alert.owner == :operator
      assert alert.subject =~ "claude:#{account.slug}"
    end

    test "fires on its own timer, with no one calling it" do
      %{ws: ws} = blind_install!()
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      pid = start_watch(initial_delay_ms: 0)

      assert_receive {:event,
                      %{kind: "alert", event: "raised", alert_kind: "quota_snapshot_stale"}},
                     5_000

      # Let the check that raised it finish before the test tears it down.
      assert %{checks: 1} = StalenessWatch.state(pid)
    end

    test "the alert says how long accounting has been blind, and that the 5h side fails open" do
      blind_install!()
      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.detail =~ "blind for 19h"
      assert alert.detail =~ "5h gate is failing open"
      assert alert.detail =~ "5h overage detection"
    end

    test "the alert says a 7d hold is in force, and when it lifts" do
      reset_7d = ahead(2 * 86_400)

      %{ws: ws} =
        blind_install!(%{
          utilization_7d: 0.96,
          status_7d: "allowed_warning",
          reset_7d_at: reset_7d
        })

      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.detail =~ "7d hold: IN FORCE for #{ws.name} (7d quota 0.96 ≥ 0.90)"

      assert alert.detail =~
               "lifts when the 7d window resets at #{DateTime.to_iso8601(reset_7d)}"
    end

    test "the alert says when no 7d hold is in force" do
      blind_install!(%{utilization_7d: 0.40, status_7d: "allowed"})
      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.detail =~ "7d hold: none in force (last reading 40% used"
    end

    test "a 7d hold is not reported for a :continue workspace, which never holds" do
      ws = workspace!()

      Ash.update!(ws, %{config: %{"quota" => %{"on_exhaustion" => "continue"}}})

      account = account!()
      link!(ws, account)
      snapshot!(account, %{captured_at: ago(19 * 3_600), utilization_7d: 0.96})

      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.detail =~ "7d hold: none in force"
    end

    test "the alert says a reached 5h cap keeps being recorded until its window resets" do
      reset_5h = ahead(1_800)

      blind_install!(%{
        captured_at: ago(2 * 3_600),
        status_5h: "rejected",
        utilization_5h: 1.0,
        reset_5h_at: reset_5h
      })

      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()

      assert alert.detail =~
               "recorded as overage until it resets at #{DateTime.to_iso8601(reset_5h)}"
    end

    test "the alert says so when the poll is succeeding but not carrying the 5h figure" do
      %{account: account} = blind_install!()
      polled_at = ago(120)

      Ash.create!(
        AnthropicQuota,
        %{
          provider_account_id: account.id,
          provider: "claude",
          per_model_utilization: %{},
          extra_usage: %{},
          oauth_captured_at: polled_at
        },
        action: :record_oauth_usage
      )

      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.detail =~ "last succeeded at #{DateTime.to_iso8601(polled_at)}"
    end
  end

  describe "benign vs actionable (AC 2)" do
    test "an account with no snapshot at all (fresh install) raises nothing" do
      ws = workspace!()
      account = account!()
      link!(ws, account)
      account_id = account.id

      pid = start_watch()
      StalenessWatch.check_now(pid)

      assert Alerts.active() == []
      assert %{accounts: %{^account_id => %{status: :no_snapshot}}} = StalenessWatch.state(pid)
    end

    test "a row the poll never wrote a 5h figure into is still 'no snapshot yet'" do
      ws = workspace!()
      account = account!()
      link!(ws, account)

      Ash.create!(
        AnthropicQuota,
        %{
          provider_account_id: account.id,
          provider: "claude",
          per_model_utilization: %{},
          extra_usage: %{},
          oauth_captured_at: ago(19 * 3_600)
        },
        action: :record_oauth_usage
      )

      StalenessWatch.check_now(start_watch())

      assert Alerts.active() == []
    end

    test "an install with no Claude account linked anywhere raises nothing" do
      workspace!()
      assert {:ok, results} = StalenessWatch.check_now(start_watch())
      assert results == %{}
      assert Alerts.active() == []
    end

    test "a fresh snapshot raises nothing" do
      ws = workspace!()
      account = account!()
      link!(ws, account)
      snapshot!(account, %{captured_at: ago(60)})

      pid = start_watch()
      StalenessWatch.check_now(pid)

      assert Alerts.active() == []
      account_id = account.id
      assert %{accounts: %{^account_id => %{status: :fresh}}} = StalenessWatch.state(pid)
    end

    test "a stale snapshot on an account no workspace is metered under is not watched" do
      orphan = account!()
      snapshot!(orphan, %{captured_at: ago(19 * 3_600)})

      StalenessWatch.check_now(start_watch())

      assert Alerts.active() == []
    end
  end

  describe "edge-triggered and self-clearing (AC 4)" do
    test "stays one alert across repeated checks" do
      blind_install!()
      pid = start_watch()

      for _ <- 1..3, do: StalenessWatch.check_now(pid)

      assert [alert] = stale_alerts()
      assert alert.raise_count == 3
    end

    test "clears by itself when a fresh snapshot lands" do
      %{account: account} = blind_install!()
      pid = start_watch()
      StalenessWatch.check_now(pid)
      assert [alert] = stale_alerts()

      snapshot!(account, %{captured_at: ago(30)})
      StalenessWatch.check_now(pid)

      assert stale_alerts() == []
      assert Ash.get!(SystemAlert, alert.id).cleared_at
    end

    test "a later stale episode opens a new alert" do
      %{account: account} = blind_install!()
      pid = start_watch()
      StalenessWatch.check_now(pid)
      assert [first] = stale_alerts()

      snapshot!(account, %{captured_at: ago(30)})
      StalenessWatch.check_now(pid)
      assert stale_alerts() == []

      snapshot!(account, %{captured_at: ago(5 * 3_600)})
      StalenessWatch.check_now(pid)

      assert [second] = stale_alerts()
      refute second.id == first.id
    end

    test "one account going stale leaves another account's state alone" do
      %{account: stale_account} = blind_install!()

      healthy_ws = workspace!()
      healthy = account!()
      link!(healthy_ws, healthy)
      snapshot!(healthy, %{captured_at: ago(60)})

      StalenessWatch.check_now(start_watch())

      assert [alert] = stale_alerts()
      assert alert.key == "claude:#{stale_account.id}"
    end

    test "an account whose alert cannot be built does not stop the others being checked" do
      %{account: healthy_account, ws: healthy_ws} = blind_install!()
      broken_account = account!()

      {:ok, [entry]} = StalenessWatch.read_claude_snapshots()

      # Stale, but malformed: its workspace has no name, so building its
      # alert raises. Listed first, so a raise that escaped would skip the
      # healthy account's alert and the clearing after it.
      broken_entry = %{
        account: broken_account,
        workspaces: [%{id: Ecto.UUID.generate()}],
        quota: %AnthropicQuota{
          provider_account_id: broken_account.id,
          provider: "claude",
          captured_at: ago(19 * 3_600)
        }
      }

      watch = start_watch(read_fun: fn -> {:ok, [broken_entry, entry]} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, results} = StalenessWatch.check_now(watch)
          assert results[healthy_account.id].status == :stale
        end)

      assert log =~ "claude:#{broken_account.slug}"
      assert [alert] = stale_alerts()
      assert alert.workspace_id == healthy_ws.id
    end

    test "a check that cannot read the snapshots raises and clears nothing" do
      blind_install!()
      pid = start_watch()
      StalenessWatch.check_now(pid)
      assert [alert] = stale_alerts()

      broken = start_watch(read_fun: fn -> {:error, :database_busy} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :database_busy} = StalenessWatch.check_now(broken)
        end)

      assert log =~ "database_busy"
      assert [%{id: id}] = stale_alerts()
      assert id == alert.id
    end
  end

  describe "the threshold (AC 1)" do
    test "defaults to 1800 s, never below the gate's own polled threshold" do
      assert StalenessWatch.threshold_seconds("oauth_poll") == 1_800

      assert StalenessWatch.threshold_seconds("oauth_poll") >=
               Gate.staleness_threshold_seconds("oauth_poll")
    end

    test "is configurable under :arbiter, :quota" do
      Application.put_env(
        :arbiter,
        :quota,
        Keyword.put(Application.get_env(:arbiter, :quota), :stale_alert_threshold_seconds, 7_200)
      )

      %{account: account} = blind_install!(%{captured_at: ago(3_600)})
      pid = start_watch()
      StalenessWatch.check_now(pid)
      assert stale_alerts() == []

      snapshot!(account, %{captured_at: ago(3 * 3_600)})
      StalenessWatch.check_now(pid)
      assert [_alert] = stale_alerts()
    end

    test "a configured threshold below the gate's is raised to it, per the row's source" do
      Application.put_env(
        :arbiter,
        :quota,
        Keyword.put(Application.get_env(:arbiter, :quota), :stale_alert_threshold_seconds, 60)
      )

      assert StalenessWatch.threshold_seconds("oauth_poll") ==
               Gate.staleness_threshold_seconds("oauth_poll")

      # 10 minutes old: past a 60 s setting, but the gate still trusts a polled
      # row this young — so the gate is not failing open, and nothing alerts.
      %{account: account} = blind_install!(%{captured_at: ago(600)})
      pid = start_watch()
      StalenessWatch.check_now(pid)
      assert stale_alerts() == []

      # The same age on a header-captured row is past that source's 300 s.
      snapshot!(account, %{captured_at: ago(600), capture_source: "headers"})
      StalenessWatch.check_now(pid)
      assert [_alert] = stale_alerts()
    end
  end

  describe "enabled: false" do
    test "never checks on its own" do
      %{ws: ws} = blind_install!()
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      pid = start_watch(enabled: false, initial_delay_ms: 0, interval_ms: 10)

      refute_receive {:event, %{kind: "alert"}}, 300
      assert %{enabled: false, checks: 0} = StalenessWatch.state(pid)
      assert stale_alerts() == []
    end
  end
end
