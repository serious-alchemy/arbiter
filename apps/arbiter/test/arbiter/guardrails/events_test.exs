defmodule Arbiter.Guardrails.EventsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Event
  alias Arbiter.Guardrails.Events
  alias Arbiter.Tasks.PermissionEvent
  alias Arbiter.Worker.Egress.Event, as: EgressEvent

  defp egress!(run_id, host, attrs \\ %{}) do
    Ash.create!(
      EgressEvent,
      Map.merge(
        %{
          run_id: run_id,
          task_id: "bd-t",
          host: host,
          port: 443,
          decision: :deny,
          policy_verdict: :deny,
          mode: :enforce,
          reason: :not_granted
        },
        attrs
      )
    )
  end

  describe "record/1" do
    test "writes a row with the severity, source and subject given" do
      assert :ok =
               Events.record(%{
                 run_id: "r1",
                 task_id: "bd-t",
                 provider: "claude",
                 model: "opus",
                 kind: :hidden_channel_attempt,
                 severity: :critical,
                 source: :transcript_scan,
                 tool: "Bash",
                 detail: "systemd-run"
               })

      assert [%Event{kind: :hidden_channel_attempt, severity: :critical, provider: "claude"}] =
               Events.for_run("r1")
    end

    test "is idempotent on the same fingerprint within a run" do
      attrs = %{
        run_id: "r1",
        kind: :credential_read,
        severity: :major,
        source: :transcript_scan,
        detail: "~/.ssh"
      }

      assert :ok = Events.record(attrs)
      assert :ok = Events.record(attrs)
      assert [_] = Events.for_run("r1")

      assert :ok = Events.record(%{attrs | detail: "~/.aws"})
      assert [_, _] = Events.for_run("r1")
    end

    test "an invalid event is swallowed, not raised" do
      assert :error = Events.record(%{run_id: "r1", kind: :bogus, severity: :major, source: :x})
      assert [] = Events.for_run("r1")
    end

    test "events are append-only" do
      types = Event |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.uniq()
      assert Enum.sort(types) == [:create, :read]
    end
  end

  describe "link_egress/1" do
    test "a denial at a public upload host is critical and links the egress row" do
      row = egress!("r2", "files.catbox.moe", %{reason: :public_upload})

      assert :ok = Events.link_egress("r2", provider: "gemini", model: "agy")

      assert [
               %Event{
                 kind: :public_upload_attempt,
                 severity: :critical,
                 source: :egress,
                 egress_event_id: egress_id,
                 provider: "gemini"
               }
             ] = Events.for_run("r2")

      assert egress_id == row.id
    end

    test "a denial for a host the run never asked about is major" do
      egress!("r3", "evil.example")
      assert :ok = Events.link_egress("r3")

      assert [%Event{kind: :unrequested_egress, severity: :major, detail: "evil.example:443"}] =
               Events.for_run("r3")
    end

    test "a denial for a host named in a permission_request is not an event" do
      egress!("r4", "status.example.com")

      Ash.create!(PermissionEvent, %{
        issue_id: "bd-t",
        permission: "network:status.example.com",
        event: :requested,
        source: :request,
        run_id: "r4"
      })

      assert :ok = Events.link_egress("r4")
      assert [] = Events.for_run("r4")
    end

    test "allowed rows and learn-mode would-be denials are not events; repeats collapse" do
      egress!("r5", "ok.example", %{decision: :allow, policy_verdict: :allow, reason: :baseline})
      egress!("r5", "learn.example", %{decision: :allow, mode: :learn})
      egress!("r5", "evil.example")
      egress!("r5", "evil.example")

      assert :ok = Events.link_egress("r5")
      assert :ok = Events.link_egress("r5")
      assert [%Event{detail: "evil.example:443"}] = Events.for_run("r5")
    end
  end

  describe "record_self_grant/3" do
    test "resolves the task's current run and its subject" do
      {:ok, run} =
        Ash.create(Arbiter.Workers.Run, %{
          task_id: "bd-sg",
          repo: "arbiter",
          started_at: DateTime.utc_now(),
          provider: "gemini",
          model: "agy-flash"
        })

      scope = %Arbiter.MCP.Scope{tier: :worker, task_id: "bd-sg"}

      assert :ok =
               Events.record_self_grant(scope, "workspace_config_set guardrails.x",
                 tool: "workspace_config_set"
               )

      assert [
               %Event{
                 kind: :self_grant_attempt,
                 severity: :critical,
                 source: :bridge_audit,
                 task_id: "bd-sg",
                 provider: "gemini",
                 model: "agy-flash",
                 tool: "workspace_config_set"
               }
             ] = Events.for_run(run.id)
    end

    test "an explicit run_id wins; with no run at all the task id stands in" do
      scope = %Arbiter.MCP.Scope{tier: :worker, task_id: "bd-sg2"}
      assert :ok = Events.record_self_grant(scope, "POST /api/mcp/tokens", run_id: "r-explicit")
      assert [%Event{task_id: "bd-sg2"}] = Events.for_run("r-explicit")

      assert :ok = Events.record_self_grant(scope, "ticket_update permissions")
      assert [%Event{}] = Events.for_run("bd-sg2")
    end
  end

  describe "severity helpers" do
    test "critical_or_major?/1 reads a run's events" do
      assert Events.count_by_severity("r6") == %{}

      Events.record(%{
        run_id: "r6",
        kind: :credential_read,
        severity: :major,
        source: :transcript_scan,
        detail: "a"
      })

      Events.record(%{
        run_id: "r6",
        kind: :permission_denial,
        severity: :minor,
        source: :claude_permission_denials,
        detail: "b"
      })

      assert Events.count_by_severity("r6") == %{major: 1, minor: 1}
    end
  end
end
