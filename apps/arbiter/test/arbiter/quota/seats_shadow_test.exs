defmodule Arbiter.Quota.SeatsShadowTest do
  @moduledoc """
  DC4 is shadow only (bd-5oquxn; design §10, I1/I2): seats are computed per
  (account, pool), but nothing on an admission, gate, dispatch, scheduler or
  run-stopping path reads them, and today's per-account count is unchanged.
  These tests pin the construction, and that a real worker and a real
  admission stamp what `Arbiter.Quota.Seats` reads.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.Seats
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @lib Path.expand("../../../lib", __DIR__)
  @consumers ~r/alias Arbiter\.Quota\.Seats|\bSeats\.(counts|count|holders|tally|base_task_id)\(/

  test "only the seats module itself names it" do
    offenders =
      @lib
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&(Path.relative_to(&1, @lib) == "arbiter/quota/seats.ex"))
      |> Enum.filter(&(File.read!(&1) =~ @consumers))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end

  test "neither the web app nor the CLI reads it yet" do
    for app <- ~w(arbiter_web arbiter_cli) do
      root = Path.expand("../../../../#{app}/lib", __DIR__)

      offenders =
        root
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ @consumers))

      assert offenders == [], "#{app} reads the seats"
    end
  end

  describe "a real dispatch" do
    @repo ResumeSlotFixture.repo()

    setup do
      ResumeSlotFixture.setup_repo!()
      ResumeSlotFixture.put_local_cap(10)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "seats-#{System.unique_integer([:positive])}",
          prefix: "st#{System.unique_integer([:positive])}"
        })

      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "seats-#{System.unique_integer([:positive])}",
          max_concurrent: 2
        })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

      %{ws: ws, account: account}
    end

    test "the worker stamps its account and pool, and the pin seat and legacy count agree", ctx do
      %{ws: ws, account: account} = ctx
      {:ok, issue} = Ash.create(Issue, %{title: "seat me", workspace_id: ws.id})

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.dispatch(issue.id, force: true, repo: @repo, start_driver: false)

      assert %{account_id: account_id, pool: "claude"} =
               Enum.find(WorkerRegistry.live_dispatches(), &(&1.pid == pid))

      assert account_id == account.id
      assert Seats.count(account.id, "claude") == 1
      # Today's count is untouched, and agrees here.
      assert Concurrency.live_count(account) == 1
    end
  end
end
