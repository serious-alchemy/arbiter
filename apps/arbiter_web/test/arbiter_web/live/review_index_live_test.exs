defmodule ArbiterWeb.ReviewIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Events
  alias Arbiter.Reviews.Record
  alias Arbiter.Tasks.{Issue, Workspace}

  # Workspaces, the record page, and a row's transcript all arrive by
  # `start_async/3` on the connected mount / event only (bd-blnnu3); tests
  # that aren't exercising the loading/error states themselves want the
  # page once every pending async has landed.
  @async_timeout 5_000

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rev-#{System.unique_integer([:positive])}", prefix: "rv"})

    {:ok, ws: ws}
  end

  defp live_reviews(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp record!(ws, attrs) do
    base = %{
      pr_ref: "github:acme/widgets##{System.unique_integer([:positive])}",
      workspace_id: ws.id,
      strategy: "github",
      status: :completed,
      mode: :auto,
      started_at: DateTime.utc_now()
    }

    {:ok, record} = Ash.create(Record, Map.merge(base, attrs))
    record
  end

  # bd-crk6tb: engagements (`review_only` with a `source_pr`) are hidden from
  # every ticket list, so /reviews is the one place they appear.
  defp engagement!(ws, source_pr, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "Review engagement: #{source_pr}",
        tracker_type: :none,
        source_pr: source_pr,
        workspace_id: ws.id
      })

    {:ok, issue} =
      Ash.update(issue, Map.merge(%{review_only: true}, attrs), action: :update)

    issue
  end

  describe "engagements (bd-crk6tb)" do
    test "lists an open engagement with its mode, review count, last review and task link",
         %{conn: conn, ws: ws} do
      reviewed_at = ~U[2026-09-01 10:30:00Z]

      eng =
        engagement!(ws, "77", %{
          review_automation: :report_only,
          review_count: 3,
          last_reviewed_at: reviewed_at
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      row = "#engagement-row-#{eng.id}"
      assert has_element?(view, "#engagements-table #{row}")
      assert has_element?(view, "#{row} [data-role=source-pr]", "77")
      assert has_element?(view, "#{row} [data-role=automation]", "report_only")
      assert has_element?(view, "#{row} [data-role=review-count]", "3")
      assert has_element?(view, "#{row} [data-role=last-reviewed]", "2026-09-01 10:30")
      assert has_element?(view, ~s(#{row} a[href="/tasks/#{eng.id}"]))
    end

    test "shows the workspace's run history joined to the engagement via engagement_id",
         %{conn: conn, ws: ws} do
      eng = engagement!(ws, "78")

      older =
        record!(ws, %{pr: "78", engagement_id: eng.id, started_at: ~U[2026-09-01 09:00:00Z]})

      newer =
        record!(ws, %{pr: "78", engagement_id: eng.id, started_at: ~U[2026-09-02 09:00:00Z]})

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      row = "#engagement-row-#{eng.id}"
      assert has_element?(view, "#{row} [data-role=run-count]", "2")
      assert has_element?(view, "#{row} [data-role=latest-run]", "2026-09-02")
      # The same runs stay in the run-history ledger below.
      assert has_element?(view, "#review-row-#{older.id}")
      assert has_element?(view, "#review-row-#{newer.id}")
    end

    test "closed engagements are listed apart from the open ones", %{conn: conn, ws: ws} do
      open = engagement!(ws, "79")
      closed = engagement!(ws, "80")
      {:ok, _} = Ash.update(closed, %{}, action: :close)

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      assert has_element?(view, "#engagements-table #engagement-row-#{open.id}")
      refute has_element?(view, "#engagements-table #engagement-row-#{closed.id}")
      assert has_element?(view, "#closed-engagements #engagement-row-#{closed.id}")
    end

    test "tickets that merely look like engagements are not listed", %{conn: conn, ws: ws} do
      {:ok, worker_review} =
        Ash.create(Issue, %{title: "worker review", review_only: true, workspace_id: ws.id})

      {:ok, follow_up} =
        Ash.create(Issue, %{
          title: "follow up",
          tracker_type: :none,
          source_pr: "81",
          workspace_id: ws.id
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      refute has_element?(view, "#engagement-row-#{worker_review.id}")
      refute has_element?(view, "#engagement-row-#{follow_up.id}")
    end

    test "the workspace filter scopes engagements and their run history", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "rev-eng-other-#{System.unique_integer([:positive])}",
          prefix: "re"
        })

      mine = engagement!(ws, "82")
      theirs = engagement!(other_ws, "83")

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      assert has_element?(view, "#engagement-row-#{mine.id}")
      assert has_element?(view, "#engagement-row-#{theirs.id}")

      view
      |> element("form")
      |> render_change(%{"workspace_id" => ws.id, "status" => ""})

      render_async(view, @async_timeout)

      assert has_element?(view, "#engagement-row-#{mine.id}")
      refute has_element?(view, "#engagement-row-#{theirs.id}")
    end

    test "with no engagements the section shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live_reviews(conn, "/reviews")

      assert has_element?(view, "#engagements-empty")
      refute has_element?(view, "#engagements-table")
    end

    test "the Reviews nav entry is in the rail", %{conn: conn} do
      {:ok, view, _html} = live_reviews(conn, "/reviews")

      assert has_element?(view, ~s(#nav-rail a[aria-current="page"][href="/reviews"]))
    end
  end

  describe "mount" do
    test "renders the header and filters when there are no records", %{conn: conn} do
      {:ok, _view, html} = live_reviews(conn, "/reviews")

      assert html =~ "Reviews"
      assert html =~ "No external reviews match"
    end

    test "lists a record's columns", %{conn: conn, ws: ws} do
      record =
        record!(ws, %{
          pr_ref: "github:acme/widgets#42",
          pr: "42",
          status: :completed,
          verdict: :approve,
          finding_count: 3,
          cost_usd: 0.12
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      row = view |> element("#review-row-#{record.id}") |> render()

      assert row =~ "42"
      assert row =~ ws.name
      assert row =~ "github"
      assert row =~ "completed"
      assert row =~ "approve"
    end
  end

  describe "filters" do
    test "workspace filter narrows the list", %{conn: conn, ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "rev-other-#{System.unique_integer([:positive])}",
          prefix: "ro"
        })

      record!(ws, %{pr: "in-ws"})
      record!(other_ws, %{pr: "other-ws"})

      {:ok, view, html} = live_reviews(conn, "/reviews")
      assert html =~ "in-ws"
      assert html =~ "other-ws"

      view
      |> element("form")
      |> render_change(%{"workspace_id" => ws.id, "status" => ""})

      html = render_async(view, @async_timeout)

      assert html =~ "in-ws"
      refute html =~ "other-ws"
    end

    test "status filter narrows the list", %{conn: conn, ws: ws} do
      record!(ws, %{pr: "running-one", status: :running})
      record!(ws, %{pr: "failed-one", status: :failed, failure_stage: "post"})

      {:ok, view, html} = live_reviews(conn, "/reviews")
      assert html =~ "running-one"
      assert html =~ "failed-one"

      view
      |> element("form")
      |> render_change(%{"workspace_id" => "", "status" => "failed"})

      html = render_async(view, @async_timeout)

      refute html =~ "running-one"
      assert html =~ "failed-one"
    end
  end

  describe "transcript in the detail view (bd-7efini)" do
    setup do
      prev = Application.get_env(:arbiter, :output_log_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "review-transcript-live-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      :ok
    end

    @stream_json Enum.join(
                   [
                     ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"s-1"}),
                     ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Checking the nil guard."}]}}),
                     ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"lib/foo.ex"}}]}}),
                     ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"defmodule Foo do"}]}}),
                     ~s({"type":"result","subtype":"success","result":"one finding"})
                   ],
                   "\n"
                 )

    test "expanding a review renders its prompt, tool uses and transcript", %{conn: conn, ws: ws} do
      record = record!(ws, %{pr: "with-transcript"})

      :ok =
        Arbiter.Worker.PromptLog.write(record.id, "You are a code reviewer. Review this diff.")

      :ok = Arbiter.Reviews.Transcript.write(record.id, @stream_json)

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      # prompt
      assert html =~ "You are a code reviewer. Review this diff."
      # tool-use record: name, input and what came back
      assert html =~ "Read"
      assert html =~ "lib/foo.ex"
      assert html =~ "defmodule Foo do"
      # transcript body
      assert html =~ "Checking the nil guard."
      assert html =~ "one finding"
      assert html =~ "claude-opus-5"
      # size of the corpus
      assert html =~ "5 lines"
    end

    test "a review with no captured transcript says so instead of rendering an empty shell", %{
      conn: conn,
      ws: ws
    } do
      record = record!(ws, %{pr: "no-transcript"})

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      assert html =~ "No transcript captured"
    end

    test "collapsing the row drops the loaded transcript", %{conn: conn, ws: ws} do
      record = record!(ws, %{pr: "toggles"})
      :ok = Arbiter.Reviews.Transcript.write(record.id, @stream_json)

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      view |> element("#review-row-#{record.id}") |> render_click()
      assert render_async(view, @async_timeout) =~ "Checking the nil guard."

      refute view |> element("#review-row-#{record.id}") |> render_click() =~
               "Checking the nil guard."
    end
  end

  describe "detail expansion" do
    test "shows findings summary and failure diagnostics for a failed review", %{
      conn: conn,
      ws: ws
    } do
      record =
        record!(ws, %{
          pr: "fails",
          status: :failed,
          findings_summary: "2 findings surfaced before failure",
          failure_stage: "post_comment",
          failure_reason: "forge returned 502"
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      assert html =~ "2 findings surfaced before failure"
      assert html =~ "post_comment"
      assert html =~ "forge returned 502"
    end

    test "shows proposed comments for a completed_unposted review", %{conn: conn, ws: ws} do
      record =
        record!(ws, %{
          pr: "unposted",
          status: :completed_unposted,
          mode: :report_only,
          greenlight_status: :pending,
          proposed_comments: [
            %{
              "file" => "lib/foo.ex",
              "line" => 12,
              "severity" => "high",
              "message" => "possible nil deref",
              "body" => "consider a guard clause"
            }
          ]
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      assert html =~ "lib/foo.ex"
      assert html =~ "possible nil deref"
      assert html =~ "high"
    end

    test "renders a link to the linked engagement task", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "engagement task", workspace_id: ws.id})

      record = record!(ws, %{pr: "engaged", engagement_id: task.id})

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      assert html =~ ~s(href="/tasks/#{task.id}")
    end

    test "collapses again on a second click", %{conn: conn, ws: ws} do
      record = record!(ws, %{pr: "toggle-me", findings_summary: "one finding"})

      {:ok, view, _html} = live_reviews(conn, "/reviews")

      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)
      assert html =~ "one finding"

      html = view |> element("#review-row-#{record.id}") |> render_click()
      refute html =~ "one finding"
    end
  end

  describe "live updates" do
    test "a running -> completed transition patches the row without a full reload", %{
      conn: conn,
      ws: ws
    } do
      record =
        record!(ws, %{pr: "live-update", status: :running, verdict: nil, finding_count: nil})

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      row = view |> element("#review-row-#{record.id}") |> render()
      assert row =~ "running"

      {:ok, updated} =
        Ash.update(record, %{status: :completed, verdict: :approve, finding_count: 5},
          action: :complete
        )

      Events.broadcast(ws.id, "external_review", %{
        status: "completed",
        pr_ref: updated.pr_ref,
        verdict: :approve,
        finding_count: 5,
        mode: :auto,
        review_record_id: updated.id,
        engagement_id: nil
      })

      row = view |> element("#review-row-#{record.id}") |> render()

      assert row =~ "completed"
      assert row =~ "approve"
      assert row =~ "5"
    end
  end

  describe "coordinator inbox broadcasts" do
    test "surviving a coordinator-mailbox message on the shared PubSub topic", %{
      conn: conn,
      ws: ws
    } do
      {:ok, view, _html} = live_reviews(conn, "/reviews")
      ref = Process.monitor(view.pid)

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        Arbiter.Messages.Message.topic(ws.id),
        {:new_message, %{id: "msg-1"}}
      )

      refute_receive {:DOWN, ^ref, :process, _pid, _reason}, 200
      assert render(view) =~ "Reviews"
    end
  end

  # bd-db3wxp: the findings summary is worker-authored markdown.
  describe "findings summary markdown" do
    test "renders the findings summary as formatted HTML", %{conn: conn, ws: ws} do
      record =
        record!(ws, %{
          pr: "md-findings",
          findings_summary: "## Findings\n\n- **one** thing\n- another\n"
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      assert html =~ "<h2>Findings</h2>"
      assert html =~ "<strong>one</strong>"
      assert html =~ "<li>another</li>"
      refute html =~ "## Findings"
    end

    test "strips XSS payloads from the findings summary", %{conn: conn, ws: ws} do
      record =
        record!(ws, %{
          pr: "md-xss",
          findings_summary:
            "<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[c](javascript:alert(1))\n"
        })

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      refute html =~ "<script"
      refute html =~ "onerror="
      refute html =~ "javascript:"
    end
  end

  # bd-blnnu3: workspaces (mount) and the record page (first-render
  # handle_params) used to run synchronously on both the dead and connected
  # render. They now arrive by `start_async/3` on the connected mount only.
  describe "the async load" do
    setup do
      :meck.new(ArbiterWeb.ReviewIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.ReviewIndexLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads neither workspaces nor records", %{
      conn: conn
    } do
      test = self()

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_workspaces, fn ->
        send(test, :workspaces_read)
        :meck.passthrough([])
      end)

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_records_page, fn workspace_id,
                                                                      status,
                                                                      page ->
        send(test, :records_read)
        :meck.passthrough([workspace_id, status, page])
      end)

      doc = conn |> get("/reviews") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query(~s(#reviews-panel[data-state="loading"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("#reviews-loading") |> Enum.count() == 1
      refute_received :workspaces_read
      refute_received :records_read
    end

    test "renders a loading skeleton before the record page lands, then the data", %{
      conn: conn,
      ws: ws
    } do
      record!(ws, %{pr: "loading-record"})

      test = self()

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_records_page, fn workspace_id,
                                                                      status,
                                                                      page ->
        result = :meck.passthrough([workspace_id, status, page])
        send(test, {:loading_records, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_records_load, self()})
        end

        result
      end)

      {:ok, view, _html} = live(conn, "/reviews")
      assert_receive {:loading_records, loader}

      assert has_element?(view, ~s(#reviews-panel[data-state="loading"]))
      assert has_element?(view, "#reviews-loading")
      refute has_element?(view, "#reviews-table")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#reviews-panel[data-state="loaded"]))
      refute has_element?(view, "#reviews-loading")
      assert html =~ "loading-record"
      refute_received {:unreleased_records_load, _}
    end

    @tag :capture_log
    test "a failed record-page load renders an inline error, and Retry recovers", %{
      conn: conn,
      ws: ws
    } do
      record!(ws, %{pr: "behind-the-error"})

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_records_page, fn _workspace_id,
                                                                      _status,
                                                                      _page ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, "/reviews")
      render_async(view, @async_timeout)

      assert has_element?(view, ~s(#reviews-panel[data-state="error"]))
      assert has_element?(view, "#reviews-error", "database is locked")
      assert has_element?(view, "#reviews-retry")
      refute has_element?(view, "#reviews-loading")

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_records_page, fn workspace_id,
                                                                      status,
                                                                      page ->
        :meck.passthrough([workspace_id, status, page])
      end)

      view |> element("#reviews-retry") |> render_click()
      html = render_async(view, @async_timeout)

      refute has_element?(view, "#reviews-error")
      assert has_element?(view, ~s(#reviews-panel[data-state="loaded"]))
      assert html =~ "behind-the-error"
    end

    @tag :capture_log
    test "a failed workspaces load renders an inline error, and Retry recovers", %{conn: conn} do
      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_workspaces, fn ->
        raise "workspaces down"
      end)

      {:ok, view, _html} = live(conn, "/reviews")
      render_async(view, @async_timeout)

      assert has_element?(view, "#reviews-workspaces-error", "workspaces down")
      assert has_element?(view, "#reviews-workspaces-retry")

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_workspaces, fn ->
        :meck.passthrough([])
      end)

      view |> element("#reviews-workspaces-retry") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#reviews-workspaces-error")
    end
  end

  describe "transcript async load (bd-blnnu3)" do
    setup do
      prev = Application.get_env(:arbiter, :output_log_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "review-transcript-async-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:arbiter, :output_log_root, root)

      :meck.new(ArbiterWeb.ReviewIndexLive, [:passthrough, :no_link])

      on_exit(fn ->
        :meck.unload(ArbiterWeb.ReviewIndexLive)
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      :ok
    end

    @stream_json Enum.join(
                   [
                     ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"s-1"}),
                     ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Checking the nil guard."}]}}),
                     ~s({"type":"result","subtype":"success","result":"one finding"})
                   ],
                   "\n"
                 )

    test "expanding a row shows a loading state before the transcript lands, then the data", %{
      conn: conn,
      ws: ws
    } do
      record = record!(ws, %{pr: "async-transcript"})
      :ok = Arbiter.Reviews.Transcript.write(record.id, @stream_json)

      test = self()

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_transcript, fn record_id ->
        result = :meck.passthrough([record_id])
        send(test, {:loading_transcript, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_transcript_load, self()})
        end

        result
      end)

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      assert_receive {:loading_transcript, loader}

      assert has_element?(view, "#review-transcript-loading-#{record.id}")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      refute has_element?(view, "#review-transcript-loading-#{record.id}")
      assert html =~ "Checking the nil guard."
      refute_received {:unreleased_transcript_load, _}
    end

    @tag :capture_log
    test "a failed transcript load renders an inline error, and Retry recovers", %{
      conn: conn,
      ws: ws
    } do
      record = record!(ws, %{pr: "transcript-error"})

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_transcript, fn _record_id ->
        raise "disk on fire"
      end)

      {:ok, view, _html} = live_reviews(conn, "/reviews")
      view |> element("#review-row-#{record.id}") |> render_click()
      render_async(view, @async_timeout)

      assert has_element?(view, "#review-transcript-error-#{record.id}", "disk on fire")
      assert has_element?(view, "#review-transcript-retry-#{record.id}")

      :meck.expect(ArbiterWeb.ReviewIndexLive, :load_transcript, fn record_id ->
        :meck.passthrough([record_id])
      end)

      view |> element("#review-transcript-retry-#{record.id}") |> render_click()
      html = render_async(view, @async_timeout)

      refute has_element?(view, "#review-transcript-error-#{record.id}")
      assert html =~ "No transcript captured"
    end
  end
end
