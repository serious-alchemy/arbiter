defmodule Arbiter.Trackers.CloseNeverRegressesTest do
  @moduledoc """
  A close pushed to a tracker must never move an upstream ticket *backwards*
  (bd-4i7kky).

  `Sync.close_and_verify/1` transitions the ticket to the workspace's
  `status_map.closed` and then re-fetches it; when the re-fetch does not look
  closed it issues a follow-up close. When `closed` maps to an intermediate
  status (the documented setting when the tracker's `Done` means "deployed"),
  a ticket other people had already moved past it — Jira `QA`, Shortcut
  `Deployed` — read as "still open", and the transition dragged it back.

  Every test drives the real entry point against a stubbed HTTP layer and
  records the *writes* the adapter attempts.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers.Sync

  @jira_ref "AX-1"
  @jira_env "GTE_CLOSE_REGRESS_JIRA_TOKEN"
  @shortcut_env "GTE_CLOSE_REGRESS_SHORTCUT_TOKEN"
  @github_env "GTE_CLOSE_REGRESS_GITHUB_TOKEN"
  @gitlab_env "GTE_CLOSE_REGRESS_GITLAB_TOKEN"

  setup do
    for env <- [@jira_env, @shortcut_env, @github_env, @gitlab_env],
        do: System.put_env(env, "test-token")

    on_exit(fn ->
      for env <- [@jira_env, @shortcut_env, @github_env, @gitlab_env], do: System.delete_env(env)
    end)

    :ok
  end

  defp workspace(type, config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "#{type}-ws-#{System.unique_integer([:positive])}",
        prefix: "cr",
        config: %{"tracker" => %{"type" => type, "config" => config}}
      })

    ws
  end

  defp issue(ws, type, ref) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "tracked",
        tracker_type: type,
        tracker_ref: ref,
        skip_upstream_create: true,
        workspace_id: ws.id
      })

    issue
  end

  defp escalations_for(ws_id) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.workspace_id == ws_id and &1.kind == :escalation))
  end

  # Drain every `{:wrote, ...}` the stub sent.
  defp writes(acc \\ []) do
    receive do
      {:wrote, w} -> writes([w | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---- Jira ----------------------------------------------------------------

  defp jira_ws(status_map, extra \\ %{}) do
    workspace(
      "jira",
      Map.merge(
        %{
          "host" => "acme.atlassian.net",
          "project_key" => "AX",
          "credentials_ref" => "env:#{@jira_env}",
          "email" => "tester@example.com",
          "status_map" => status_map
        },
        extra
      )
    )
  end

  # A Jira whose ticket sits in `{name, category}` and whose workflow lets it
  # move straight to every status in `reachable` (`{name, category}`).
  defp stub_jira(current, reachable) do
    test_pid = self()
    {cur_name, cur_cat} = current

    Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and String.ends_with?(path, "/transitions") ->
          transitions =
            for {{name, cat}, i} <- Enum.with_index(reachable, 100) do
              %{
                "id" => "#{i}",
                "name" => "Go to #{name}",
                "to" => %{"name" => name, "statusCategory" => %{"key" => cat}}
              }
            end

          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"transitions" => transitions})

        conn.method == "GET" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "key" => @jira_ref,
            "fields" => %{
              "status" => %{"name" => cur_name, "statusCategory" => %{"key" => cur_cat}}
            }
          })

        conn.method == "POST" and String.ends_with?(path, "/transitions") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:wrote, {:jira_transition, Jason.decode!(body)}})
          conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
      end
    end)
  end

  describe "Jira" do
    test "QA -> Code Complete: a ticket past the closed-mapped status is left alone" do
      # The bd-4i7kky incident: `closed => "Code Complete"`, the ticket already
      # in QA, and QA has a live transition back to Code Complete.
      ws = jira_ws(%{"closed" => "Code Complete"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"QA", "indeterminate"}, [{"Code Complete", "indeterminate"}])

      log = capture_log(fn -> assert :ok = Sync.close_and_verify(issue) end)

      assert writes() == []
      assert escalations_for(ws.id) == []
      refute log =~ "follow-up close"
    end

    test "a ticket in Jira's done category is never moved back to an intermediate closed status" do
      ws = jira_ws(%{"closed" => "Code Complete"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"Released", "done"}, [{"Code Complete", "indeterminate"}])

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
    end

    test "a ticket still in To Do (new category) is closed to the intermediate status" do
      ws = jira_ws(%{"closed" => "Code Complete"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"To Do", "new"}, [{"Code Complete", "indeterminate"}])

      assert :ok = Sync.close_and_verify(issue)
      assert [{:jira_transition, %{"transition" => %{"id" => "100"}}} | _] = writes()
    end

    test "a ticket in a status arbiter itself drove it to (In Code Review) is still closed" do
      ws = jira_ws(%{"closed" => "Code Complete"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"In Code Review", "indeterminate"}, [{"Code Complete", "indeterminate"}])

      assert :ok = Sync.close_and_verify(issue)
      assert [{:jira_transition, %{"transition" => %{"id" => "100"}}} | _] = writes()
    end

    test "a status the transition_graph routes into the closed status is still closed" do
      # The documented escape hatch: name the workspace's own pre-close statuses
      # in `transition_graph` and they count as open.
      ws =
        jira_ws(%{"closed" => "Code Complete"}, %{
          "transition_graph" => %{
            "Peer Review" => [%{"transition" => "Approve", "to" => "Code Complete"}]
          }
        })

      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"Peer Review", "indeterminate"}, [{"Code Complete", "indeterminate"}])

      assert :ok = Sync.close_and_verify(issue)
      assert [{:jira_transition, %{"transition" => %{"id" => "100"}}} | _] = writes()
    end

    test "closed => Done (a done-category target) still closes a ticket from any open status" do
      ws = jira_ws(%{"closed" => "Done"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"QA", "indeterminate"}, [{"Done", "done"}])

      assert :ok = Sync.close_and_verify(issue)
      assert [{:jira_transition, %{"transition" => %{"id" => "100"}}} | _] = writes()
    end

    test "a ticket already at the intermediate closed status gets no follow-up close" do
      # The close landed (or someone else put it there). `Code Complete` is not
      # in Jira's done category, so the old verify read this as "still open".
      ws = jira_ws(%{"closed" => "Code Complete"})
      issue = issue(ws, :jira, @jira_ref)

      stub_jira({"Code Complete", "indeterminate"}, [])

      log = capture_log(fn -> assert :ok = Sync.close_and_verify(issue) end)

      assert writes() == []
      assert escalations_for(ws.id) == []
      refute log =~ "follow-up close"
    end
  end

  # ---- Shortcut ------------------------------------------------------------

  defp shortcut_ws(closed) do
    workspace("shortcut", %{
      "credentials_ref" => "env:#{@shortcut_env}",
      "status_map" => %{"closed" => closed}
    })
  end

  # Shortcut workflow: Unstarted(0) < In Progress(1) < Ready for Deploy(2) <
  # QA(3), all `started`, then Deployed(4) `done`.
  @shortcut_workflow [
    %{
      "id" => 100,
      "name" => "Engineering",
      "states" => [
        %{"id" => 500, "name" => "Unstarted", "type" => "unstarted", "position" => 0},
        %{"id" => 501, "name" => "In Progress", "type" => "started", "position" => 1},
        %{"id" => 502, "name" => "Ready for Deploy", "type" => "started", "position" => 2},
        %{"id" => 503, "name" => "QA", "type" => "started", "position" => 3},
        %{"id" => 504, "name" => "Deployed", "type" => "done", "position" => 4}
      ]
    }
  ]

  defp stub_shortcut(state_id) do
    test_pid = self()

    Req.Test.stub(Arbiter.Trackers.Shortcut.HTTP, fn conn ->
      path = conn.request_path

      cond do
        conn.method == "GET" and String.ends_with?(path, "/workflows") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(@shortcut_workflow)

        conn.method == "GET" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "id" => 1234,
            "workflow_state_id" => state_id,
            "completed" => state_id == 504
          })

        conn.method == "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:wrote, {:shortcut_put, Jason.decode!(body)}})
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 1234})
      end
    end)
  end

  describe "Shortcut" do
    test "a story already in a LATER started state (QA) is not dragged back to Ready for Deploy" do
      ws = shortcut_ws("Ready for Deploy")
      issue = issue(ws, :shortcut, "1234")

      stub_shortcut(503)

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
      assert escalations_for(ws.id) == []
    end

    test "a story in a done-type state is not dragged back to a started-type closed status" do
      ws = shortcut_ws("Ready for Deploy")
      issue = issue(ws, :shortcut, "1234")

      stub_shortcut(504)

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
    end

    test "a story already in the closed-mapped state is not rewritten" do
      ws = shortcut_ws("Ready for Deploy")
      issue = issue(ws, :shortcut, "1234")

      stub_shortcut(502)

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
    end

    test "a story in an EARLIER state is moved forward to the closed-mapped state" do
      ws = shortcut_ws("Ready for Deploy")
      issue = issue(ws, :shortcut, "1234")

      stub_shortcut(501)

      assert :ok = Sync.close_and_verify(issue)
      assert [{:shortcut_put, %{"workflow_state_id" => 502}} | _] = writes()
    end

    test "closed => Done still closes a story from any earlier state" do
      ws = shortcut_ws("Deployed")
      issue = issue(ws, :shortcut, "1234")

      stub_shortcut(503)

      assert :ok = Sync.close_and_verify(issue)
      assert [{:shortcut_put, %{"workflow_state_id" => 504}} | _] = writes()
    end
  end

  # ---- GitHub / GitLab -----------------------------------------------------
  #
  # Both trackers have two states, so a close can only ever move an `open`
  # issue to `closed`. These pin that: an issue somebody already closed is
  # neither re-closed nor reopened, and no follow-up fires.

  describe "GitHub" do
    test "an already-closed issue is not written to again" do
      test_pid = self()

      ws =
        workspace("github", %{
          "owner" => "acme",
          "repo" => "widgets",
          "credentials_ref" => "env:#{@github_env}"
        })

      issue = issue(ws, :github, "673")

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        if conn.method != "GET", do: send(test_pid, {:wrote, {:github, conn.method}})

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 673, "state" => "closed", "labels" => []})
      end)

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
    end
  end

  describe "GitLab" do
    test "an already-closed issue is not written to again" do
      test_pid = self()

      ws =
        workspace("gitlab", %{
          "host" => "gitlab.com",
          "project_id" => 42,
          "credentials_ref" => "env:#{@gitlab_env}"
        })

      issue = issue(ws, :gitlab, "7")

      Req.Test.stub(Arbiter.Trackers.Gitlab.HTTP, fn conn ->
        if conn.method != "GET", do: send(test_pid, {:wrote, {:gitlab, conn.method}})

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => 7, "state" => "closed", "labels" => []})
      end)

      assert :ok = Sync.close_and_verify(issue)
      assert writes() == []
    end
  end
end
