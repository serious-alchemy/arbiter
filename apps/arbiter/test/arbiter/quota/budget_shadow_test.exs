defmodule Arbiter.Quota.BudgetShadowTest do
  @moduledoc """
  DC3 is shadow only (bd-6c8g4t; design §10, I1/I2/I8): the provider budget is
  computed and published, but nothing on an admission, gate, dispatch,
  scheduler or run-stopping path reads it. Until DC8 no dispatch decision may
  change, and these tests pin the construction.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server

  @lib Path.expand("../../../lib", __DIR__)

  # `Quota.Budget` itself (not `BudgetCalibration`, which DC2's test owns),
  # its server and inputs, or a call through an alias of any of them.
  @consumers ~r/Quota\.Budget(?!Calibration)\b|\bBudget\.(compute|publish|hysteresis|new_hysteresis|lowest|explore|expiring|Server|Inputs)\b/

  # The budget's own modules, and the supervision tree that starts its server.
  @allowed ~w(
    arbiter/quota/budget.ex
    arbiter/quota/budget/server.ex
    arbiter/quota/budget/inputs.ex
    arbiter/application.ex
  )

  defp source_files(root) do
    root |> Path.join("**/*.{ex,exs}") |> Path.wildcard()
  end

  test "only the budget's own modules and the supervision tree name it" do
    offenders =
      @lib
      |> source_files()
      |> Enum.reject(&(Path.relative_to(&1, @lib) in @allowed))
      |> Enum.filter(&(File.read!(&1) =~ @consumers))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end

  test "neither the web app nor the CLI reads it yet" do
    for app <- ~w(arbiter_web arbiter_cli) do
      root = Path.expand("../../../../#{app}/lib", __DIR__)
      offenders = root |> source_files() |> Enum.filter(&(File.read!(&1) =~ @consumers))
      assert offenders == [], "#{app} reads the budget"
    end
  end

  test "the admission surfaces never name the budget or its published table" do
    surfaces = ~w(
      arbiter/accounts/admission.ex
      arbiter/accounts/concurrency.ex
      arbiter/accounts/slot_limit.ex
      arbiter/quota/gate.ex
      arbiter/board/autopilot.ex
      arbiter/board/scheduler.ex
      arbiter/board/snapshot.ex
      arbiter/workflows/dispatch_queue.ex
      arbiter/worker/dispatch.ex
      arbiter/worker/resume_slot.ex
      arbiter/agents/provider_routing.ex
      arbiter/agents/reviewer_routing.ex
      arbiter/nodes/placement.ex
      arbiter/nodes/capacity.ex
    )

    existing = for rel <- surfaces, File.exists?(Path.join(@lib, rel)), do: rel
    assert length(existing) > 8

    for rel <- existing do
      source = File.read!(Path.join(@lib, rel))
      refute source =~ @consumers, "#{rel} reads the provider budget"
      refute source =~ "arbiter_quota_budgets", "#{rel} reads the budget table"
    end
  end

  test "nothing that stops a run reads it (I8)" do
    stoppers = Path.join(@lib, "arbiter/worker/**/*.ex") |> Path.wildcard()
    assert stoppers != []
    assert Enum.filter(stoppers, &(File.read!(&1) =~ @consumers)) == []
  end

  test "the budget reaches Pace only through the gate (I6)" do
    source = File.read!(Path.join(@lib, "arbiter/quota/budget.ex"))
    refute source =~ ~r/\bPace\./
    refute source =~ "alias Arbiter.Quota.Pace"
  end

  test "a published zero budget changes no account's headroom" do
    account = %ProviderAccount{id: Ecto.UUID.generate(), provider: :claude, max_concurrent: 3}
    before = Concurrency.account_headroom(account, nil)

    inputs = fn _calibration ->
      [%{account_id: account.id, account: account, pool: "claude", quota: nil, hard: :paused}]
    end

    table = :budget_shadow_table

    start_supervised!(
      {Server,
       name: :budget_shadow_server,
       table: table,
       inputs: inputs,
       enabled: true,
       tick_ms: :never,
       calibration: :never}
    )

    :ok = Server.recompute(:budget_shadow_server)
    assert %Budget{budget: 0, binding: :paused} = Server.get(account.id, "claude", nil, table)

    assert Concurrency.account_headroom(account, nil) == before
    assert Concurrency.limit(account, nil) == 3
  end
end
