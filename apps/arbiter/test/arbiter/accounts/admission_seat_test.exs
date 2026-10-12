defmodule Arbiter.Accounts.AdmissionSeatTest do
  @moduledoc """
  `Admission.admit/3` under `scheduler_admission: enforce` (DC8, design
  `provider-dynamic-concurrency.md` §4.4, E3, E4): a fresh dispatch is admitted
  while the seats on its pool are below `min(budget, max_concurrent, share)`
  (`Arbiter.Accounts.SeatCheck`), under the same per-account lock and with the
  same reservation, override and refusal as today. Under `legacy` and `shadow`
  the account's process count against `max_concurrent` decides, exactly as
  before (AC1).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  setup do
    ws =
      Ash.create!(Workspace, %{
        name: "seat-#{System.unique_integer([:positive])}",
        prefix: "se#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "seat-#{System.unique_integer([:positive])}",
        max_concurrent: 3
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    task = Ash.create!(Issue, %{title: "fresh", workspace_id: ws.id})
    on_exit(fn -> Admission.release(task.id) end)

    %{ws: ws, account: account, task: task}
  end

  defp budget(account, n, pool \\ "claude") do
    %Budget{
      account: account.id,
      pool: pool,
      budget: n,
      binding: {:window, "5h"},
      reason: "5h ahead of its line",
      ceiling: %{max_concurrent: account.max_concurrent, share: nil}
    }
  end

  defp seated(account, n, pool \\ "claude"),
    do: %{{account.id, pool} => Enum.map(1..n//1, &"bd-held-#{&1}")}

  defp admit(ctx, mode, seat_opts, extra \\ []) do
    Admission.admit(
      ctx.task,
      :claude,
      [account: ctx.account, mode: mode, seat_opts: seat_opts] ++ extra
    )
  end

  describe "enforce" do
    test "refuses a fresh dispatch when the pool's seats reach its budget, under max_concurrent",
         ctx do
      seat_opts = [budgets: [budget(ctx.account, 1)], holders: seated(ctx.account, 1)]

      assert {:error, {:account_at_capacity, info}} = admit(ctx, :enforce, seat_opts)
      assert %{cap: 1, pool: "claude", holders: ["bd-held-1"], task_id: task_id} = info
      assert task_id == ctx.task.id
      assert Admission.pending() |> Enum.filter(&(&1.registry_key == ctx.task.id)) == []
    end

    test "admits while a seat is free, and the reservation seats on the checked pool", ctx do
      seat_opts = [budgets: [budget(ctx.account, 2)], holders: seated(ctx.account, 1)]

      assert {:ok, :admitted} = admit(ctx, :enforce, seat_opts)

      assert [%{account_id: account_id, pool: "claude"}] =
               Enum.filter(Admission.pending(), &(&1.registry_key == ctx.task.id))

      assert account_id == ctx.account.id
    end

    test "the account's max_concurrent still caps a larger budget", ctx do
      seat_opts = [budgets: [budget(ctx.account, 9)], holders: seated(ctx.account, 3)]
      assert {:error, {:account_at_capacity, %{cap: 3}}} = admit(ctx, :enforce, seat_opts)
    end

    test "a planned pool is the one checked and reserved", ctx do
      agy =
        Ash.create!(ProviderAccount, %{
          provider: :antigravity,
          slug: "agy-#{System.unique_integer([:positive])}"
        })

      gpt = "antigravity:claude_and_gpt_models"

      seat_opts = [
        budgets: [
          budget(agy, 0, "antigravity:gemini_models"),
          budget(agy, 1, gpt)
        ],
        holders: %{}
      ]

      assert {:ok, :admitted} =
               Admission.admit(ctx.task, :gemini,
                 account: agy,
                 mode: :enforce,
                 pool: gpt,
                 seat_opts: seat_opts
               )

      assert [%{pool: ^gpt}] = Enum.filter(Admission.pending(), &(&1.registry_key == ctx.task.id))
    end

    test "force goes over a full pool, reserved and recorded", ctx do
      seat_opts = [budgets: [budget(ctx.account, 0)], holders: %{}]

      assert {:ok, :forced} = admit(ctx, :enforce, seat_opts, force: true, actor: "operator:test")

      [event] =
        Arbiter.Events.Record
        |> Ash.Query.filter(workspace_id == ^ctx.ws.id and topic == "account_cap_override")
        |> Ash.read!()

      assert event.payload["cap"] == 0
      assert event.payload["actor"] == "operator:test"
    end

    test "the refusal names the pool's seats and why", ctx do
      seat_opts = [budgets: [budget(ctx.account, 1)], holders: seated(ctx.account, 1)]
      {:error, {:account_at_capacity, info}} = admit(ctx, :enforce, seat_opts)

      message = Admission.refusal_message(info)
      assert message =~ "1 of 1 seats"
      assert message =~ "5h ahead of its line"
      assert message =~ ctx.task.id
    end
  end

  describe "legacy and shadow (AC1)" do
    for mode <- [:legacy, :shadow] do
      test "#{mode}: the budget is not read; max_concurrent against live workers decides", ctx do
        # A budget of 0 with seats held would refuse under enforce; no live
        # worker is on the account, so today's check admits.
        seat_opts = [budgets: [budget(ctx.account, 0)], holders: seated(ctx.account, 3)]
        assert {:ok, :admitted} = admit(ctx, unquote(mode), seat_opts)
      end
    end
  end
end
