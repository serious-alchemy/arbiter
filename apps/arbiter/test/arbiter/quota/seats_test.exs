defmodule Arbiter.Quota.SeatsTest do
  @moduledoc """
  DC4 (bd-5oquxn; design `docs/design/provider-dynamic-concurrency.md` §3.2):
  seats per (account, pool), derived from the worker registry. The pure core
  (`holders/2`) first, then the registry-backed `counts/0` against real
  processes and tickets.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.Seats
  alias Arbiter.Repo
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  @a "acct-a"
  @b "acct-b"

  defp entry(key, account, pool, extra \\ %{}) do
    Map.merge(
      %{
        registry_key: key,
        workspace_id: "ws",
        provider: "claude",
        account_id: account,
        pool: pool
      },
      extra
    )
  end

  defp counts(entries, pinned), do: entries |> Seats.holders(MapSet.new(pinned)) |> Seats.tally()

  describe "holders/2 (pure)" do
    test "a ticket In progress holds one pin seat on its primary's pool" do
      assert counts([entry("t1", @a, "claude")], ["t1"]) == %{{@a, "claude"} => 1}
    end

    test "a ticket that is not In progress holds no pin seat" do
      assert counts([entry("t1", @a, "claude")], []) == %{}
    end

    test "a same-pool sub-worker adds nothing: the ticket counts once per pool" do
      entries = [entry("t1", @a, "claude"), entry("t1:fixpass", @a, "claude")]
      assert counts(entries, ["t1"]) == %{{@a, "claude"} => 1}
    end

    test "a cross-pool sub-worker takes a seat on its own pool as well as the pin seat" do
      entries = [entry("t1", @a, "claude"), entry("t1#review", @b, "codex")]

      assert counts(entries, ["t1"]) == %{{@a, "claude"} => 1, {@b, "codex"} => 1}
    end

    test "a cross-pool sub-worker on the same account but another pool is a separate pool" do
      entries = [
        entry("t1", @a, "antigravity:gemini_models"),
        entry("t1#review", @a, "antigravity:claude_and_gpt_models")
      ]

      assert counts(entries, ["t1"]) == %{
               {@a, "antigravity:gemini_models"} => 1,
               {@a, "antigravity:claude_and_gpt_models"} => 1
             }
    end

    test "two live sub-workers on a foreign pool are two seats: one per live worker" do
      entries = [
        entry("t1", @a, "claude"),
        entry("t1#review", @b, "codex"),
        entry("t1:fixpass", @b, "codex")
      ]

      assert counts(entries, ["t1"]) == %{{@a, "claude"} => 1, {@b, "codex"} => 2}
    end

    test "sub-workers of a ticket that is not In progress each take a seat (a Merging fix pass)" do
      entries = [entry("t1", @a, "claude"), entry("t1:fixpass", @a, "claude")]
      assert counts(entries, []) == %{{@a, "claude"} => 1}
    end

    test "a parked primary and a released primary keep the pin seat" do
      entries = [
        entry("t1", @a, "claude", %{released: true}),
        entry("t1#review", @b, "codex"),
        entry("t2", @a, "claude", %{released: false})
      ]

      assert counts(entries, ["t1", "t2"]) == %{{@a, "claude"} => 2, {@b, "codex"} => 1}
    end

    test "a reservation seats its pool until its worker registers" do
      reserved = entry("t1", @a, "claude", %{reservation: true})

      assert counts([reserved], []) == %{{@a, "claude"} => 1}
    end

    test "a reservation shadowed by the registered worker is not counted twice" do
      reserved = entry("t1", @a, "claude", %{reservation: true})
      assert counts([entry("t1", @a, "claude"), reserved], ["t1"]) == %{{@a, "claude"} => 1}
    end

    test "separate tickets always count separately" do
      entries = [entry("t1", @a, "claude"), entry("t2", @a, "claude")]
      assert counts(entries, ["t1", "t2"]) == %{{@a, "claude"} => 2}
    end

    test "an entry with no known account or pool is not seated anywhere" do
      assert counts([entry("t1", nil, "claude"), entry("t2", @a, nil)], ["t1", "t2"]) == %{}
    end

    test "a holder is named by the ticket for a pin seat and by the key for a sub-worker" do
      entries = [entry("t1", @a, "claude"), entry("t1#review", @b, "codex")]

      assert Seats.holders(entries, MapSet.new(["t1"])) == %{
               {@a, "claude"} => ["t1"],
               {@b, "codex"} => ["t1#review"]
             }
    end
  end

  describe "registry stamping" do
    test "put_dispatch stamps the account and the pool, and keeps them across a rewrite" do
      key = "stamp-#{System.unique_integer([:positive])}"
      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(WorkerRegistry, key, nil)

          :ok =
            WorkerRegistry.put_dispatch(key, "ws", "agy",
              account_id: "acct-1",
              model: "claude-sonnet-4-5"
            )

          send(test, :stamped)

          receive do
            :rewrite ->
              :ok = WorkerRegistry.put_dispatch(key, "ws", "agy", released: true)
              send(test, :rewritten)
              Process.sleep(:infinity)
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :stamped

      assert %{account_id: "acct-1", pool: "antigravity:claude_and_gpt_models"} =
               Enum.find(WorkerRegistry.live_dispatches(), &(&1.registry_key == key))

      send(pid, :rewrite)
      assert_receive :rewritten

      assert %{account_id: "acct-1", pool: "antigravity:claude_and_gpt_models", released: true} =
               Enum.find(WorkerRegistry.live_dispatches(), &(&1.registry_key == key))
    end
  end

  describe "counts/0 (registry and tickets)" do
    defp workspace!,
      do: Ash.create!(Workspace, %{name: "seats-#{System.unique_integer([:positive])}"})

    defp account!(provider, attrs \\ %{}) do
      Ash.create!(
        ProviderAccount,
        Map.merge(
          %{provider: provider, slug: "seats-#{System.unique_integer([:positive])}"},
          attrs
        )
      )
    end

    defp link!(ws, provider, account) do
      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: provider,
        provider_account_id: account.id
      })
    end

    defp ticket!(ws, state) do
      id = "seat-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Repo.query!(
        """
        INSERT INTO issues (id, workspace_id, title, issue_type, priority, tracker_type,
                            state, created_at, updated_at)
        VALUES (?1, ?2, ?1, 'feature', 2, 'none', ?3, ?4, ?4)
        """,
        [id, ws.id, to_string(state), now]
      )

      id
    end

    # A stand-in for `Arbiter.Worker`: stamps what `Worker.init/1` stamps.
    defp fake_worker(key, ws, provider, opts \\ []) do
      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(WorkerRegistry, key, nil)
          :ok = WorkerRegistry.put_dispatch(key, ws.id, provider, opts)
          send(test, {:registered, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:registered, ^pid}
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    setup do
      ws = workspace!()
      # A ceiling, so admission reserves (an unbounded account has nothing to count).
      claude = account!(:claude, %{max_concurrent: 5})
      codex = account!(:codex)
      link!(ws, :claude, claude)
      link!(ws, :codex, codex)
      %{ws: ws, claude: claude, codex: codex}
    end

    test "an In-progress ticket seats its pin pool, a cross-pool reviewer seats its own", ctx do
      t = ticket!(ctx.ws, :active)
      fake_worker(t, ctx.ws, "claude", account_id: ctx.claude.id)
      fake_worker(t <> "#review", ctx.ws, "codex", account_id: ctx.codex.id)

      counts = Seats.counts()
      assert counts[{ctx.claude.id, "claude"}] == 1
      assert counts[{ctx.codex.id, "codex"}] == 1
      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "the account is resolved from the workspace when the entry did not stamp one", ctx do
      t = ticket!(ctx.ws, :active)
      fake_worker(t, ctx.ws, "claude")

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "a provider-less entry falls back to the workspace's default provider", ctx do
      t = ticket!(ctx.ws, :active)
      fake_worker(t, ctx.ws, nil)

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "a Merging ticket's parked primary holds nothing, its fix pass holds a seat", ctx do
      t = ticket!(ctx.ws, :merging)
      fake_worker(t, ctx.ws, "claude")
      fake_worker(t <> ":fixpass", ctx.ws, "claude")

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "a ticket released to wait for CI keeps its pin seat", ctx do
      t = ticket!(ctx.ws, :active)
      fake_worker(t, ctx.ws, "claude", released: true)

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "a worker whose ticket cannot be read fails closed and seats", ctx do
      fake_worker("seat-no-such-ticket", ctx.ws, "claude")

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "an admitted dispatch with no worker yet seats its reservation", ctx do
      t = ticket!(ctx.ws, :ready)
      test = self()

      pid =
        spawn(fn ->
          issue = Ash.get!(Arbiter.Tasks.Issue, t)
          {:ok, _} = Arbiter.Accounts.Admission.admit(issue, :claude, account: ctx.claude)
          send(test, :reserved)
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :reserved

      assert Seats.count(ctx.claude.id, "claude") == 1
    end

    test "a killed worker releases its seat with no decrement", ctx do
      t = ticket!(ctx.ws, :active)
      pid = fake_worker(t, ctx.ws, "claude")
      assert Seats.count(ctx.claude.id, "claude") == 1

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Seats.count(ctx.claude.id, "claude") == 0
    end
  end
end
