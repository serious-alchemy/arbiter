defmodule Arbiter.Tasks.IssueLifecycleTest do
  @moduledoc """
  bd-842qio (ticket lifecycle 1/13): the stored `state`, its named
  transitions, `close_reason`, `rank`, and the legacy dual-write, exercised
  through the `Issue` actions.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Lifecycle, Workspace}

  # The ticket's transition table, spelled out here rather than read from
  # `Lifecycle`, so the enumeration below checks the actions against the
  # ticket and not against the code under test.
  @table [
    {:promote, :backlog, :queued},
    {:demote, :queued, :backlog},
    {:start, :queued, :active},
    {:open_pr, :active, :merging},
    {:return_to_work, :merging, :active},
    {:await_verification, :active, :verifying},
    {:await_verification, :merging, :verifying},
    {:close, :backlog, :closed},
    {:close, :queued, :closed},
    {:close, :active, :closed},
    {:close, :merging, :closed},
    {:close, :verifying, :closed},
    {:reopen, :closed, :queued},
    {:reopen, :verifying, :queued}
  ]

  @states [:backlog, :queued, :active, :merging, :verifying, :closed]
  @targets @table |> Enum.map(fn {t, _from, to} -> {t, to} end) |> Enum.uniq()

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "lc-#{System.unique_integer([:positive])}", prefix: "lc"})

    {:ok, ws: ws}
  end

  defp ticket(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  # A fresh ticket walked into `state` through the transitions themselves.
  defp in_state(ws, state, attrs \\ %{})
  defp in_state(ws, :backlog, attrs), do: ticket(ws, attrs)
  defp in_state(ws, :queued, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:promote)
  defp in_state(ws, :active, attrs), do: ws |> in_state(:queued, attrs) |> transition!(:start)
  defp in_state(ws, :merging, attrs), do: ws |> in_state(:active, attrs) |> transition!(:open_pr)

  defp in_state(ws, :verifying, attrs),
    do: ws |> in_state(:active, attrs) |> transition!(:await_verification)

  defp in_state(ws, :closed, attrs), do: ws |> in_state(:backlog, attrs) |> transition!(:close)

  defp transition!(issue, transition, args \\ %{}) do
    {:ok, next} = Ash.update(issue, args, action: transition)
    next
  end

  defp reload(issue), do: Ash.get!(Issue, issue.id)

  describe "the state attribute (AC1)" do
    test "a new ticket is :backlog", %{ws: ws} do
      assert ticket(ws).state == :backlog
      assert reload(ticket(ws)).state == :backlog
    end

    test "is non-null and constrained to the six states" do
      attr = Ash.Resource.Info.attribute(Issue, :state)

      assert attr.allow_nil? == false
      assert attr.default == :backlog
      assert attr.constraints[:one_of] == Lifecycle.states()
    end

    test "no create path can place a ticket anywhere but :backlog", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Issue, %{title: "sneaky", workspace_id: ws.id, state: :queued})
    end
  end

  describe "the transition table (AC4)" do
    for issue_type <- [:feature, :task] do
      test "#{issue_type}: exactly the table's (from, to) pairs succeed; every other pair is an error",
           %{ws: ws} do
        results =
          for from <- @states, to <- @states, {transition, ^to} <- @targets do
            issue = in_state(ws, from, %{issue_type: unquote(issue_type)})

            outcome =
              case Ash.update(issue, %{}, action: transition) do
                {:ok, %Issue{state: ^to}} ->
                  :ok

                {:error, %Ash.Error.Invalid{}} ->
                  # Refused, and nothing was written.
                  assert reload(issue).state == from
                  :error

                other ->
                  {:unexpected, other}
              end

            {transition, from, to, outcome}
          end

        assert for({t, f, to, {:unexpected, _} = o} <- results, do: {t, f, to, o}) == []

        succeeded = for {t, f, to, :ok} <- results, do: {t, f, to}
        assert Enum.sort(succeeded) == Enum.sort(@table)

        # 6 from-states × the 8 (transition, target) pairs.
        assert length(results) == 48
      end
    end

    test "a no-PR (`task`) ticket goes active → closed and active → verifying directly",
         %{ws: ws} do
      active = in_state(ws, :active, %{issue_type: :task})
      assert {:ok, %Issue{state: :closed}} = Ash.update(active, %{}, action: :close)

      active = in_state(ws, :active, %{issue_type: :task})

      assert {:ok, %Issue{state: :verifying}} =
               Ash.update(active, %{}, action: :await_verification)
    end

    test "every transition in Lifecycle has a named action of the same name" do
      for transition <- Lifecycle.transitions() do
        assert %{type: :update} = Ash.Resource.Info.action(Issue, transition),
               "no :#{transition} action on Issue"
      end
    end

    test "a refusal names the transition and the state it was refused from", %{ws: ws} do
      issue = ticket(ws)

      assert {:error, %Ash.Error.Invalid{} = err} = Ash.update(issue, %{}, action: :start)
      message = Exception.message(err)
      assert message =~ "start"
      assert message =~ "backlog"
    end
  end

  describe ":update cannot change state (AC5)" do
    test "refuses a state input and leaves the row alone", %{ws: ws} do
      issue = ticket(ws)

      assert {:error, %Ash.Error.Invalid{} = err} = Ash.update(issue, %{state: :closed})
      assert Exception.message(err) =~ "state"
      assert reload(issue).state == :backlog
    end

    test "refuses close_reason and rank inputs too", %{ws: ws} do
      issue = ticket(ws)

      assert {:error, %Ash.Error.Invalid{}} = Ash.update(issue, %{close_reason: :wont_do})
      assert {:error, %Ash.Error.Invalid{}} = Ash.update(issue, %{rank: 1})
    end
  end

  describe "dual-write: each transition writes the legacy columns (AC6)" do
    test "backlog → status open, unrefined", %{ws: ws} do
      demoted = ws |> in_state(:queued) |> transition!(:demote)

      assert {demoted.state, demoted.status, demoted.refined} == {:backlog, :open, false}
      assert %{status: :open, refined: false} = reload(demoted)
    end

    test "queued → status open, refined", %{ws: ws} do
      promoted = in_state(ws, :queued)
      assert {promoted.state, promoted.status, promoted.refined} == {:queued, :open, true}

      # Reopen lands in the queue too, whatever `refined` was when it closed.
      reopened = ws |> in_state(:closed) |> transition!(:reopen)
      assert {reopened.state, reopened.status, reopened.refined} == {:queued, :open, true}
      assert %{status: :open, refined: true} = reload(reopened)
    end

    test "active → status in_progress, refined", %{ws: ws} do
      started = in_state(ws, :active)
      assert {started.state, started.status, started.refined} == {:active, :in_progress, true}

      returned = ws |> in_state(:merging) |> transition!(:return_to_work)

      assert {returned.state, returned.status, returned.refined} ==
               {:active, :in_progress, true}
    end

    test "merging → status in_progress, refined", %{ws: ws} do
      merging = in_state(ws, :merging)
      assert {merging.state, merging.status, merging.refined} == {:merging, :in_progress, true}
      assert %{status: :in_progress, refined: true} = reload(merging)
    end

    test "verifying → status awaiting_verification, refined", %{ws: ws} do
      verifying = in_state(ws, :verifying)

      assert {verifying.state, verifying.status, verifying.refined} ==
               {:verifying, :awaiting_verification, true}
    end

    test "closed → status closed, refined left as it was", %{ws: ws} do
      from_backlog = ws |> in_state(:backlog) |> transition!(:close)

      assert {from_backlog.state, from_backlog.status, from_backlog.refined} ==
               {:closed, :closed, false}

      from_queued = ws |> in_state(:queued) |> transition!(:close)

      assert {from_queued.state, from_queued.status, from_queued.refined} ==
               {:closed, :closed, true}
    end
  end

  describe "close_reason (AC2)" do
    test "is constrained to completed | wont_do | duplicate" do
      attr = Ash.Resource.Info.attribute(Issue, :close_reason)
      assert attr.constraints[:one_of] == [:completed, :wont_do, :duplicate]
    end

    test "defaults to :completed when the close gives none", %{ws: ws} do
      assert %Issue{close_reason: :completed} = ws |> ticket() |> transition!(:close)
    end

    test "records the reason the close gives", %{ws: ws} do
      for reason <- [:wont_do, :duplicate, :completed] do
        closed = ws |> ticket() |> transition!(:close, %{close_reason: reason})
        assert closed.close_reason == reason
        assert reload(closed).close_reason == reason
      end
    end

    test "an unknown reason is refused", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(ticket(ws), %{close_reason: :bored}, action: :close)
    end

    test "is nil in every state but :closed", %{ws: ws} do
      for state <- @states -- [:closed] do
        assert %Issue{close_reason: nil} = in_state(ws, state)
      end
    end

    test "reopen clears it", %{ws: ws} do
      closed = ws |> ticket() |> transition!(:close, %{close_reason: :wont_do})
      reopened = transition!(closed, :reopen)

      assert reopened.close_reason == nil
      assert reload(reopened).close_reason == nil
    end

    test "a verified close records :completed", %{ws: ws} do
      verifying = in_state(ws, :verifying, %{verify_after_deploy: true})

      {:ok, closed} = Arbiter.Tasks.Verification.observed(verifying, "restarted; it works")
      assert closed.close_reason == :completed
    end
  end

  describe "rank (AC3)" do
    test "a new ticket sorts after every ticket with its priority in its workspace", %{ws: ws} do
      first = ticket(ws, %{priority: 2})
      second = ticket(ws, %{priority: 2})
      assert second.rank > first.rank

      # Even past a ticket that was hand-ranked to the bottom of the band.
      set_rank!(first, 5_000_000)
      third = ticket(ws, %{priority: 2})

      band =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws.id and priority == 2)
        |> Ash.Query.sort(rank: :asc)
        |> Ash.read!()

      assert List.last(band).id == third.id
      assert Enum.all?(band -- [List.last(band)], &(&1.rank < third.rank))
    end

    test "is persisted", %{ws: ws} do
      issue = ticket(ws)
      assert is_integer(issue.rank)
      assert reload(issue).rank == issue.rank
    end

    test "another workspace's ranks don't move this workspace's", %{ws: ws} do
      {:ok, other} = Ash.create(Workspace, %{name: "lc-other", prefix: "lco"})
      other |> ticket() |> set_rank!(9_000_000_000)

      mine = ticket(ws)
      assert mine.rank < 9_000_000_000
    end
  end

  describe "the legacy doors keep the state in step" do
    test ":promote_to_ready promotes a backlog ticket and is still idempotent", %{ws: ws} do
      issue = ticket(ws)

      {:ok, promoted} = Ash.update(issue, %{}, action: :promote_to_ready)
      assert {promoted.state, promoted.refined} == {:queued, true}

      assert {:ok, %Issue{state: :queued}} = Ash.update(promoted, %{}, action: :promote_to_ready)
    end

    test ":return_to_backlog demotes a queued ticket and is still idempotent", %{ws: ws} do
      queued = in_state(ws, :queued)

      {:ok, demoted} = Ash.update(queued, %{}, action: :return_to_backlog)
      assert {demoted.state, demoted.refined} == {:backlog, false}

      assert {:ok, %Issue{state: :backlog}} =
               Ash.update(demoted, %{}, action: :return_to_backlog)
    end

    test ":return_to_backlog on an in-progress ticket whose worker stopped lands in :backlog",
         %{ws: ws} do
      # bd-2098: no live worker, so the demote resets status too.
      for state <- [:active, :merging] do
        {:ok, demoted} = ws |> in_state(state) |> Ash.update(%{}, action: :return_to_backlog)

        assert {demoted.state, demoted.status, demoted.refined} == {:backlog, :open, false}
        assert %{state: :backlog, status: :open, refined: false} = reload(demoted)
      end
    end

    test "a legacy status write through :update carries the state with it", %{ws: ws} do
      # open → in_progress: the state follows the backfill rule.
      {:ok, working} = Ash.update(ticket(ws), %{status: :in_progress})
      assert working.state == :active

      {:ok, with_pr} = Ash.update(ticket(ws), %{status: :in_progress, pr_ref: "#7"})
      assert with_pr.state == :merging

      # in_progress → open (AuthDeath, the board's drag back to Ready).
      {:ok, requeued} = Ash.update(in_state(ws, :active), %{status: :open})
      assert {requeued.state, requeued.refined} == {:queued, true}

      {:ok, back_to_backlog} = Ash.update(working, %{status: :open})
      assert {back_to_backlog.state, back_to_backlog.refined} == {:backlog, false}
    end

    test "an :update that leaves status alone leaves the state alone", %{ws: ws} do
      merging = in_state(ws, :merging)

      {:ok, renamed} = Ash.update(merging, %{title: "renamed", pr_ref: nil})
      assert renamed.state == :merging
    end
  end

  describe "broadcast_lifecycle/2 payloads (AC9)" do
    test "the PubSub \"tasks\" message carries state and close_reason", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "tasks")
      issue = ticket(ws)
      id = issue.id

      transition!(issue, :close, %{close_reason: :duplicate})

      assert_receive {:task_lifecycle, :closed,
                      %Issue{id: ^id, status: :closed, state: :closed, close_reason: :duplicate}}
    end

    test "the task_state Events payload carries state and close_reason", %{ws: ws} do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))
      issue = ticket(ws)
      id = issue.id

      assert_receive {:event, %{topic: "task_state", task_id: ^id, event: "created"} = created}
      assert created.status == "open"
      assert created.state == "backlog"
      assert created.close_reason == nil

      transition!(issue, :close, %{close_reason: :wont_do})

      assert_receive {:event, %{topic: "task_state", task_id: ^id, event: "closed"} = closed}
      assert closed.status == "closed"
      assert closed.state == "closed"
      assert closed.close_reason == "wont_do"
    end
  end

  # Forces an arbitrary absolute rank to exercise scheduler ordering. The real
  # reordering door is the `:set_rank` action (bd-djapyj, `arb issue rank`),
  # but it only supports relative moves (top/bottom/before/after), not
  # setting an arbitrary absolute value — raw SQL is still the right tool
  # here.
  defp set_rank!(issue, rank) do
    Arbiter.Repo.query!("UPDATE issues SET rank = ?1 WHERE id = ?2", [rank, issue.id])
    issue
  end
end
