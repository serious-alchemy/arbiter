defmodule Arbiter.Board.CiBackpressureTest do
  @moduledoc """
  `Arbiter.Board.CiBackpressure`: the per-repo dispatch gate driven by forge CI
  saturation (`worker.repos.<repo>.ci_backpressure`). The forge poll is a seam
  (`:poller`), so every case here runs against a stubbed forge.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Board.CiBackpressure
  alias Arbiter.Board.CiBackpressure.Cache
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-29 12:00:00Z]

  defp workspace!(backpressure \\ %{"max_pending" => 4}) do
    n = System.unique_integer([:positive])

    block =
      case backpressure do
        nil -> %{}
        bp -> %{"ci_backpressure" => bp}
      end

    Ash.create!(Workspace, %{
      name: "cibp-#{n}",
      prefix: "cibp#{n}",
      config: %{"worker" => %{"repos" => %{"vstim" => block}}}
    })
  end

  defp issue(id, ws, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        state: :queued,
        priority: 2,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "vstim"
      },
      extra
    )
  end

  # A stubbed forge: `n` pending MR pipelines, the oldest created `age_min` ago.
  defp forge(n, age_min \\ 5, counter \\ nil) do
    oldest = if n > 0, do: DateTime.add(@now, -age_min * 60, :second)

    fn _ws, _repo ->
      if counter, do: Agent.update(counter, &(&1 + 1))
      {:ok, %{pending: n, oldest_at: oldest}}
    end
  end

  defp opts(poller), do: [poller: poller, async: false, now: @now]

  describe "limits/1" do
    test "reads worker.repos.<repo>.ci_backpressure" do
      ws = workspace!(%{"max_pending" => 4, "max_oldest_pending_min" => 90})

      assert %{"vstim" => %{max_pending: 4, max_oldest_pending_min: 90}} =
               CiBackpressure.limits(ws)
    end

    test "absent config, or a block with neither threshold, is off" do
      assert CiBackpressure.limits(workspace!(nil)) == %{}
      assert CiBackpressure.limits(workspace!(%{})) == %{}
    end

    test "a stored non-positive or non-integer threshold (validation refuses it) reads as unset" do
      bad = %{"max_pending" => 0, "max_oldest_pending_min" => "soon"}
      config = %{"worker" => %{"repos" => %{"vstim" => %{"ci_backpressure" => bad}}}}
      assert CiBackpressure.limits(config) == %{}
    end
  end

  describe "evaluate/3" do
    test "holds at max_pending and names the counts" do
      limits = %{max_pending: 4, max_oldest_pending_min: nil}
      signal = %{pending: 4, oldest_at: DateTime.add(@now, -12 * 60, :second)}
      assert {:hold, "4 pending, oldest 12m"} = CiBackpressure.evaluate(limits, signal, @now)
    end

    test "below max_pending is clear" do
      limits = %{max_pending: 4, max_oldest_pending_min: nil}
      signal = %{pending: 3, oldest_at: DateTime.add(@now, -600 * 60, :second)}
      assert :ok = CiBackpressure.evaluate(limits, signal, @now)
    end

    test "holds when the oldest pending pipeline is older than max_oldest_pending_min" do
      limits = %{max_pending: nil, max_oldest_pending_min: 60}
      old = %{pending: 1, oldest_at: DateTime.add(@now, -61 * 60, :second)}
      fresh = %{pending: 1, oldest_at: DateTime.add(@now, -59 * 60, :second)}

      assert {:hold, "1 pending, oldest 61m"} = CiBackpressure.evaluate(limits, old, @now)
      assert :ok = CiBackpressure.evaluate(limits, fresh, @now)
    end

    test "an empty queue is clear whatever the thresholds" do
      limits = %{max_pending: 1, max_oldest_pending_min: 1}
      assert :ok = CiBackpressure.evaluate(limits, %{pending: 0, oldest_at: nil}, @now)
    end
  end

  describe "holds/3" do
    test "holds a Ready ticket of a saturated repo, naming the counts" do
      ws = workspace!()
      holds = CiBackpressure.holds([ws], [issue("t-1", ws)], opts(forge(6, 30)))
      assert %{"t-1" => {:hold, "6 pending, oldest 30m"}} = holds
    end

    test "below the threshold, or with no config, dispatch is unchanged" do
      ws = workspace!()
      assert CiBackpressure.holds([ws], [issue("t-1", ws)], opts(forge(3))) == %{}

      bare = workspace!(nil)
      assert CiBackpressure.holds([bare], [issue("t-1", bare)], opts(forge(50))) == %{}
    end

    test "P0 is exempt" do
      ws = workspace!()
      issues = [issue("t-p0", ws, %{priority: 0}), issue("t-p1", ws, %{priority: 1})]
      holds = CiBackpressure.holds([ws], issues, opts(forge(9)))
      assert Map.keys(holds) == ["t-p1"]
    end

    test "only fresh work is held: tickets already past Ready, and epics, are not" do
      ws = workspace!()

      issues = [
        issue("t-active", ws, %{state: :active}),
        issue("t-merging", ws, %{state: :merging}),
        issue("t-epic", ws, %{issue_type: :epic}),
        issue("t-queued", ws)
      ]

      assert Map.keys(CiBackpressure.holds([ws], issues, opts(forge(9)))) == ["t-queued"]
    end

    test "another repo, or one with no repo, is not held" do
      ws = workspace!()
      issues = [issue("t-other", ws, %{repo: "other"}), issue("t-none", ws, %{repo: nil})]
      assert CiBackpressure.holds([ws], issues, opts(forge(9))) == %{}
    end

    test "the forge is asked at most once per repo per interval" do
      ws = workspace!()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      o = opts(forge(9, 5, counter))

      for _ <- 1..3, do: CiBackpressure.holds([ws], [issue("t-1", ws), issue("t-2", ws)], o)

      assert Agent.get(counter, & &1) == 1
    end

    test "an expired interval polls again" do
      ws = workspace!()
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      o = Keyword.put(opts(forge(9, 5, counter)), :interval_ms, 0)

      CiBackpressure.holds([ws], [issue("t-1", ws)], o)
      CiBackpressure.holds([ws], [issue("t-1", ws)], o)

      assert Agent.get(counter, & &1) == 2
    end

    test "a failed poll holds for a tick, then fails open after the bounded retries, logged" do
      ws = workspace!()
      poller = fn _ws, _repo -> {:error, :timeout} end
      o = Keyword.put(opts(poller), :interval_ms, 0)
      card = [issue("t-1", ws)]

      log =
        capture_log([level: :warning], fn ->
          # The first failures are not a licence to dispatch: the card waits.
          for _ <- 1..(Cache.max_failures() - 1) do
            assert %{"t-1" => {:hold, _}} = CiBackpressure.holds([ws], card, o)
          end

          # The forge stays unreadable: fail open, as before.
          assert CiBackpressure.holds([ws], card, o) == %{}
        end)

      assert log =~ "CiBackpressure"
      assert log =~ "failing open"
    end

    test "a poller that raises is retried, then fails open too" do
      ws = workspace!()
      poller = fn _ws, _repo -> raise "forge is down" end
      o = Keyword.put(opts(poller), :interval_ms, 0)

      log =
        capture_log([level: :warning], fn ->
          results =
            for _ <- 1..Cache.max_failures(),
                do: CiBackpressure.holds([ws], [issue("t-1", ws)], o)

          assert List.last(results) == %{}
          assert Enum.all?(Enum.drop(results, -1), &match?(%{"t-1" => {:hold, _}}, &1))
        end)

      assert log =~ "failing open"
    end

    test "a failed poll is cached for the interval, not retried on every read" do
      ws = workspace!()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      poller = fn _ws, _repo ->
        Agent.update(counter, &(&1 + 1))
        {:error, :timeout}
      end

      capture_log(fn ->
        for _ <- 1..3, do: CiBackpressure.holds([ws], [issue("t-1", ws)], opts(poller))
      end)

      assert Agent.get(counter, & &1) == 1
    end

    test "a repo with no reading yet holds its card for a tick instead of failing open" do
      ws = workspace!()
      test = self()

      poller = fn _ws, _repo ->
        send(test, {:polled, self()})
        {:ok, %{pending: 9, oldest_at: DateTime.add(@now, -90 * 60, :second)}}
      end

      o = [poller: poller, async: true, now: @now]

      assert %{"t-1" => {:hold, _}} = CiBackpressure.holds([ws], [issue("t-1", ws)], o)
      assert_receive {:polled, task}
      ref = Process.monitor(task)
      assert_receive {:DOWN, ^ref, :process, ^task, _}

      # The reading has landed: the hold now names the real counts.
      assert %{"t-1" => {:hold, "9 pending, oldest 90m"}} =
               CiBackpressure.holds([ws], [issue("t-1", ws)], o)
    end

    test "verdict/3 (the merge train) still fails open with no reading" do
      ws = workspace!()
      poller = fn _ws, _repo -> {:error, :timeout} end

      capture_log(fn ->
        assert CiBackpressure.verdict(ws, "vstim", opts(poller)) == :ok
      end)
    end
  end

  describe "refresh/2 (the timer poll for repos with no queued card)" do
    test "reads the queue of every gated repo, so a later promote finds a fresh reading" do
      ws = workspace!()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      assert :ok = CiBackpressure.refresh([ws], opts(forge(9, 96, counter)))
      assert Agent.get(counter, & &1) == 1

      # A card is promoted later: no second poll, and the card is held on the reading.
      never = fn _ws, _repo -> flunk("must not poll again within the interval") end
      o = [poller: never, async: true, now: @now]

      assert %{"t-1" => {:hold, "9 pending, oldest 96m"}} =
               CiBackpressure.holds([ws], [issue("t-1", ws)], o)
    end

    test "does not poll an ungated repo" do
      ws = workspace!(nil)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      assert :ok = CiBackpressure.refresh([ws], opts(forge(9, 5, counter)))
      assert Agent.get(counter, & &1) == 0
    end
  end

  describe "hold logging" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
    end

    test "a hold and its release each log one info line, once per state change" do
      ws = workspace!()
      o = fn n, age -> Keyword.put(opts(forge(n, age)), :interval_ms, 0) end
      card = [issue("t-1", ws)]

      held =
        capture_log([level: :info], fn ->
          for _ <- 1..3, do: CiBackpressure.holds([ws], card, o.(6, 96))
        end)

      assert [line] = String.split(held, "\n", trim: true)
      assert line =~ "vstim"
      assert line =~ "6 pending"
      assert line =~ "oldest 96m"
      assert line =~ "[info]"

      released =
        capture_log([level: :info], fn ->
          for _ <- 1..3, do: CiBackpressure.holds([ws], card, o.(2, 5))
        end)

      assert [line] = String.split(released, "\n", trim: true)
      assert line =~ "vstim"
      assert line =~ "2 pending"
      assert line =~ "oldest 5m"
      assert line =~ "released"
    end

    test "a repo that was never held logs nothing" do
      ws = workspace!()

      log =
        capture_log([level: :info], fn ->
          CiBackpressure.holds([ws], [issue("t-1", ws)], opts(forge(1, 1)))
        end)

      assert log == ""
    end
  end

  describe "status/2" do
    test "one entry per configured repo: pending count, thresholds and hold state" do
      ws = workspace!(%{"max_pending" => 4, "max_oldest_pending_min" => 90})

      assert [entry] = CiBackpressure.status([ws], opts(forge(6, 30)))
      assert entry.repo == "vstim"
      assert entry.workspace_id == ws.id
      assert entry.pending == 6
      assert entry.oldest_pending_min == 30
      assert entry.max_pending == 4
      assert entry.max_oldest_pending_min == 90
      assert entry.state == "held"
      assert entry.detail == "6 pending, oldest 30m"
    end

    test "a clear queue reads clear, and an unreadable forge reads unknown" do
      ws = workspace!()
      assert [%{state: "clear", pending: 1}] = CiBackpressure.status([ws], opts(forge(1)))

      other = workspace!()
      failing = fn _ws, _repo -> {:error, :nope} end

      capture_log(fn ->
        assert [%{state: "unknown", pending: nil}] = CiBackpressure.status([other], opts(failing))
      end)
    end

    test "a workspace with no config contributes no entry" do
      assert CiBackpressure.status([workspace!(nil)], opts(forge(9))) == []
    end
  end

  # The default poller: the repo's own merger, per forge.
  describe "poll/2" do
    @env_var "CIBP_POLL_TEST_TOKEN"

    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
    end

    defp merge_ws(merge) do
      %Workspace{
        id: "poll-#{System.unique_integer([:positive])}",
        name: "poll",
        config: %{
          "merge" => merge,
          "repo_paths" => %{"vstim" => "/nonexistent/vstim"},
          "worker" => %{"repos" => %{"vstim" => %{"ci_backpressure" => %{"max_pending" => 2}}}}
        }
      }
    end

    test "asks GitLab for the project's pending MR pipelines" do
      ws =
        merge_ws(%{
          "strategy" => "gitlab",
          "config" => %{
            "host" => "gitlab.com",
            "project_id" => 777,
            "credentials_ref" => "env:#{@env_var}"
          }
        })

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        assert conn.request_path == "/api/v4/projects/777/pipelines"

        body =
          if conn.query_string =~ "status=pending",
            do: [%{"id" => 1, "created_at" => "2026-10-29T11:00:00Z"}],
            else: []

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
      end)

      assert {:ok, %{pending: 1, oldest_at: ~U[2026-10-29 11:00:00Z]}} =
               CiBackpressure.poll(ws, "vstim")
    end

    test "asks GitHub for the repo's queued pull-request runs" do
      ws =
        merge_ws(%{
          "strategy" => "github",
          "config" => %{
            "owner" => "octo",
            "repo" => "widget",
            "credentials_ref" => "env:#{@env_var}"
          }
        })

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        assert conn.request_path == "/repos/octo/widget/actions/runs"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "total_count" => 3,
          "workflow_runs" => [%{"id" => 1, "created_at" => "2026-10-29T10:00:00Z"}]
        })
      end)

      assert {:ok, %{pending: 3, oldest_at: ~U[2026-10-29 10:00:00Z]}} =
               CiBackpressure.poll(ws, "vstim")
    end

    test "a repo that merges directly has no CI queue to read: an error, so the gate fails open" do
      ws = merge_ws(%{"strategy" => "direct"})
      assert {:error, :ci_queue_unsupported} = CiBackpressure.poll(ws, "vstim")
    end
  end

  describe "verdict/3 (the speculative merge train's gate, bd-6dyva0)" do
    test "a saturated repo holds, naming the counts" do
      ws = workspace!(%{"max_pending" => 4})
      assert {:hold, "9 pending, oldest 5m"} = CiBackpressure.verdict(ws, "vstim", opts(forge(9)))
    end

    test "below the threshold is clear" do
      ws = workspace!(%{"max_pending" => 4})
      assert :ok = CiBackpressure.verdict(ws, "vstim", opts(forge(1)))
    end

    test "an ungated repo is clear without asking the forge" do
      ws = workspace!(nil)
      poller = fn _ws, _repo -> flunk("an ungated repo must not be polled") end
      assert :ok = CiBackpressure.verdict(ws, "vstim", opts(poller))
      assert :ok = CiBackpressure.verdict(nil, "vstim", opts(poller))
    end

    test "a failed poll fails open" do
      ws = workspace!(%{"max_pending" => 1})

      capture_log(fn ->
        assert :ok =
                 CiBackpressure.verdict(
                   ws,
                   "vstim",
                   opts(fn _ws, _repo -> {:error, :timeout} end)
                 )
      end)
    end
  end
end
