defmodule Arbiter.Worker.CliSet.WatcherTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.CliSet.Watcher
  alias Arbiter.Worker.CliSetFixture
  alias Arbiter.Worker.Image.PublishLedger

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    on_exit(fn -> Settings.set_worker_cli_set_hold(nil) end)

    ledger = Path.join(tmp, "ledger.term")
    now = ~U[2026-10-26 12:00:00Z]
    old = DateTime.add(now, -15 * 86_400, :second)
    recent = DateTime.add(now, -13 * 86_400, :second)

    PublishLedger.record(%{repo: "stale", repo_path: "/r/stale"}, ledger: ledger, now: old)
    PublishLedger.record(%{repo: "fresh", repo_path: "/r/fresh"}, ledger: ledger, now: recent)

    cli_opts = CliSetFixture.put(Path.join(tmp, "a"))
    test = self()

    opts = [
      name: nil,
      enabled: true,
      interval_ms: :infinity,
      boot_delay_ms: :infinity,
      ledger: ledger,
      now: now,
      cli_opts: cli_opts,
      publish: fn ctx ->
        send(test, {:published, ctx.repo})
        {:ok, %{ref: "r"}}
      end
    ]

    {:ok, opts: opts, tmp: tmp}
  end

  # A new upstream claude lands in the cache and the pin moves to it.
  defp bump(opts, tmp) do
    new = CliSetFixture.put(Path.join(tmp, "b"), claude: "2.1.311")
    Keyword.put(opts, :cli_opts, new)
  end

  defp drain(acc \\ []) do
    receive do
      {:published, repo} -> drain([repo | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  test "unheld, a bump republishes only the repos that published in the last 14 days", %{
    opts: opts,
    tmp: tmp
  } do
    pid = start_supervised!({Watcher, opts})
    assert {:republished, [{{"fresh", "/r/fresh"}, {:ok, _}}]} = Watcher.run_now(pid)
    assert drain() == ["fresh"]

    # The same set again: nothing to do.
    assert Watcher.run_now(pid) == :unchanged

    # The pin bump: pins change, the watcher is told by the settings event.
    :sys.replace_state(pid, fn state -> %{state | opts: bump(state.opts, tmp)} end)

    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      Settings.topic(),
      {:installation_settings_changed, :worker_cli_versions}
    )

    _ = :sys.get_state(pid)

    assert drain() == ["fresh"]
  end

  test "held: a bump republishes nothing", %{opts: opts, tmp: tmp} do
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")
    pid = start_supervised!({Watcher, bump(opts, tmp)})

    assert Watcher.run_now(pid) == :held

    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      Settings.topic(),
      {:installation_settings_changed, :worker_cli_versions}
    )

    _ = :sys.get_state(pid)

    assert drain() == []
  end

  test "a bump with identical bytes republishes nothing", %{opts: opts, tmp: tmp} do
    pid = start_supervised!({Watcher, opts})
    assert {:republished, _} = Watcher.run_now(pid)
    _ = drain()

    same =
      CliSetFixture.put(Path.join(tmp, "c"),
        claude: "2.1.311",
        content: %{"claude" => "claude-binary-2.1.310"}
      )

    :sys.replace_state(pid, fn state ->
      %{state | opts: Keyword.put(state.opts, :cli_opts, same)}
    end)

    assert Watcher.run_now(pid) == :unchanged
  end

  test "held, the set resolves from the held snapshot whatever the pins say now", %{tmp: tmp} do
    a = CliSetFixture.put(Path.join(tmp, "a"))
    {:ok, set} = CliSet.resolve(a)
    {:ok, set} = CliSet.materialize(set)
    {:ok, _} = Settings.set_worker_cli_set_hold(set.set8)

    b = CliSetFixture.put(Path.join(tmp, "b"), claude: "2.1.311")
    # Same sets root, new cache: the pins moved.
    b = Keyword.put(b, :cli_sets_root, Keyword.fetch!(a, :cli_sets_root))
    assert {:ok, bumped} = CliSet.resolve(Keyword.delete(b, :cli_set))
    assert bumped.hash == set.hash
    assert Enum.find(bumped.clis, &(&1.name == "claude")).version == "2.1.310"
    assert {:ok, _} = CliSet.materialize(bumped, verify: true)

    # Under the hold the shipped escript is the snapshot's, not the host's.
    escript = CliSet.arb_escript(Keyword.delete(b, :cli_set))
    assert is_binary(escript)
    assert escript =~ "/arb/arb.escript"
    assert escript =~ Keyword.fetch!(a, :cli_sets_root)

    {:ok, _} = Settings.set_worker_cli_set_hold(nil)
    assert {:ok, moved} = CliSet.resolve(b)
    refute moved.hash == set.hash
  end
end
