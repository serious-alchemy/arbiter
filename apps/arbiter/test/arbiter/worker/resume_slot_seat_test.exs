defmodule Arbiter.Worker.ResumeSlotSeatTest do
  @moduledoc """
  `ResumeSlot.admit/2` under `scheduler_admission: enforce` (DC8, design
  `provider-dynamic-concurrency.md` §3.2, §7): the board's slot cap becomes the
  pin pool's seat check.

    * A ticket In progress holds its pin seat in every phase — between rounds,
      held for quota, idle — so resuming it is a follow-up and needs nothing new.
    * A ticket not In progress (a revise of a Merging ticket, a requeued one)
      goes back into In progress: it needs a free seat on its pin pool
      (`Arbiter.Accounts.SeatCheck`), and is deferred (automatic), refused
      (human) or forced over, exactly as at a full cap today.
    * A CI fix or conflict pass (`follow_up: true`, `PassAdmission`) is a
      follow-up of in-flight work and is never held for a full pool (I9).

  Under `legacy` the same calls are today's slot rule.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Events.Record
  alias Arbiter.Quota.Budget
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ResumeSlot

  require Ash.Query

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "rss-#{System.unique_integer([:positive])}",
        prefix: "rss#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "rss-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    ticket = Ash.create!(Issue, %{title: "resume me", workspace_id: ws.id})
    %{ws: ws, account: account, ticket: ticket}
  end

  defp in_state(ticket, state), do: %{ticket | state: state}

  defp seats(ctx, budget, held) do
    [
      budgets: [
        %Budget{
          account: ctx.account.id,
          pool: "claude",
          budget: budget,
          binding: {:window, "5h"},
          reason: "5h ahead of its line"
        }
      ],
      holders: %{{ctx.account.id, "claude"} => Enum.map(1..held//1, &"bd-seat-#{&1}")}
    ]
  end

  defp admit(ticket, ctx, opts) do
    ResumeSlot.admit(ticket, [mode: :enforce, account: ctx.account] ++ opts)
  end

  describe "enforce: a ticket In progress holds its pin seat" do
    test "its resume needs nothing new, even with the pool full", ctx do
      ticket = in_state(ctx.ticket, :active)

      for origin <- [:human, :automatic] do
        assert {:ok, :held} = admit(ticket, ctx, origin: origin, seat_opts: seats(ctx, 1, 3))
      end
    end

    test "held for quota or idle, it still holds it (the seat is wider than the slot)", ctx do
      ticket = in_state(ctx.ticket, :active)

      assert {:ok, :held} =
               admit(ticket, ctx,
                 origin: :automatic,
                 held_ids: [ticket.id],
                 idle_ids: [ticket.id],
                 seat_opts: seats(ctx, 0, 0)
               )
    end
  end

  describe "enforce: a ticket not In progress needs a free seat on its pin pool" do
    test "acquired while the pool has one", ctx do
      ticket = in_state(ctx.ticket, :merging)
      assert {:ok, :acquired} = admit(ticket, ctx, seat_opts: seats(ctx, 2, 1))
    end

    test "an automatic resume is deferred at a full pool", ctx do
      ticket = in_state(ctx.ticket, :merging)

      assert {:defer, info} = admit(ticket, ctx, origin: :automatic, seat_opts: seats(ctx, 1, 1))
      assert %{task_id: task_id, cap: 1, holders: ["bd-seat-1"], seat: %{pool: "claude"}} = info
      assert task_id == ticket.id
      assert ResumeSlot.limit_phrase(info) =~ "1 of 1 seats"
    end

    test "a human resume is refused, naming the pool's seats", ctx do
      ticket = in_state(ctx.ticket, :queued)

      assert {:error, {:slot_cap_full, info}} =
               admit(ticket, ctx, origin: :human, seat_opts: seats(ctx, 1, 1))

      message = ResumeSlot.refusal_message(info)
      assert message =~ "1 of 1 seats"
      assert message =~ "5h ahead of its line"
    end

    test "force goes over, recorded", ctx do
      ticket = in_state(ctx.ticket, :merging)

      assert {:ok, :forced} =
               admit(ticket, ctx,
                 force: true,
                 actor: "operator:test",
                 seat_opts: seats(ctx, 0, 0)
               )

      assert [%{payload: %{"cap" => 0, "actor" => "operator:test"}}] =
               Record
               |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "slot_cap_override")
               |> Ash.read!()
    end

    test "the pin's account is the one checked when none is given", ctx do
      {:ok, pinned} =
        ctx.ticket
        |> Ash.Changeset.for_update(:pin_implementer, %{
          implementer_account_id: ctx.account.id,
          implementer_family: "anthropic"
        })
        |> Ash.update()

      assert {:defer, %{seat: %{account_id: account_id}}} =
               ResumeSlot.admit(in_state(pinned, :merging),
                 mode: :enforce,
                 origin: :automatic,
                 seat_opts: seats(ctx, 1, 1)
               )

      assert account_id == ctx.account.id
    end
  end

  describe "a CI fix or conflict pass (follow_up: true)" do
    test "enforce: never held for a full pool (I9)", ctx do
      ticket = in_state(ctx.ticket, :merging)

      assert {:ok, :follow_up} =
               admit(ticket, ctx,
                 origin: :automatic,
                 follow_up: true,
                 seat_opts: seats(ctx, 0, 0)
               )
    end

    test "legacy: the option changes nothing — today's slot rule", ctx do
      ticket = in_state(ctx.ticket, :merging)
      other = in_state(%{ctx.ticket | id: "bd-other"}, :active)

      assert {:defer, %{cap: 1}} =
               ResumeSlot.admit(ticket,
                 mode: :legacy,
                 origin: :automatic,
                 follow_up: true,
                 tickets: [other],
                 cap: 1
               )
    end
  end

  test "legacy: the slot rule decides and no seat is read", ctx do
    ticket = in_state(ctx.ticket, :merging)

    assert {:ok, :acquired} =
             ResumeSlot.admit(ticket,
               mode: :legacy,
               tickets: [],
               cap: 1,
               seat_opts: seats(ctx, 0, 5)
             )
  end
end
