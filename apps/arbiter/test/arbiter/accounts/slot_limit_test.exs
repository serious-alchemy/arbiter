defmodule Arbiter.Accounts.SlotLimitTest do
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.SlotLimit
  alias Arbiter.Board.Scheduler
  alias Arbiter.Worker.ResumeSlot

  @account %{name: "claude:default", limit: 2, live: 2, runs: ["bd-2qy0gu", "bd-c27m5o#review1"]}

  describe "classify/3" do
    test "names the account when its ceiling is what clamps the workspace" do
      # install 3, account 2/2 live, workspace holds 1: min(3, 1 + 0) = 1
      assert %{limit: :account, name: "claude:default", max: 2, live: 2} =
               SlotLimit.classify(3, @account, 1)
    end

    test "names the install cap when it is the lowest" do
      assert %{limit: :install, max: 3} = SlotLimit.classify(3, %{@account | limit: 9}, 3)
      assert %{limit: :install, max: 3} = SlotLimit.classify(3, nil, 3)
    end
  end

  describe "describe/2" do
    test "account: N/M live with every counted run and its role" do
      limit = SlotLimit.classify(3, @account, 1)

      assert SlotLimit.describe(limit, ["bd-2qy0gu"]) ==
               "account claude:default at 2/2 live (bd-2qy0gu implement, bd-c27m5o review)"
    end

    test "the install cap names itself" do
      assert SlotLimit.describe(%{limit: :install, max: 3}, ["bd-a"]) ==
               "the install cap is 3 and 1 held by bd-a"
    end
  end

  describe "ResumeSlot.refusal_message/1" do
    test "names the account instead of a derived cap of 1" do
      info = %{
        task_id: "bd-3t973v",
        cap: 1,
        holders: ["bd-2qy0gu"],
        limit: SlotLimit.classify(3, @account, 1)
      }

      message = ResumeSlot.refusal_message(info)

      assert message =~
               "account claude:default at 2/2 live (bd-2qy0gu implement, bd-c27m5o review)"

      refute message =~ "cap is 1"
      assert ResumeSlot.limit_phrase(info) =~ "claude:default"
    end

    test "install cap binding" do
      info = %{
        task_id: "bd-x",
        cap: 3,
        holders: ["bd-a"],
        limit: %{limit: :install, max: 3}
      }

      assert ResumeSlot.refusal_message(info) =~ "the install cap is 3 and 1 held by bd-a"
    end
  end

  test "board reason names the binding limit" do
    card = %{id: "bd-1", scope: MapSet.new(), blocked_by: [], conflicts_with: []}

    plan =
      Scheduler.plan(%{
        ready: [card],
        running: [],
        conflict_claims: %{},
        quota: :ok,
        paused: false,
        slots_free: 0,
        slot_note: "account claude:default at 2/2 live (bd-a implement)"
      })

    assert [%{reason: reason}] = plan.entries

    assert reason ==
             "blocked — no free worker slot (account claude:default at 2/2 live (bd-a implement))"
  end
end
