defmodule Arbiter.Worker.WorktreeSweeper do
  @moduledoc """
  Periodic sweep of the worktree root for dead worktree leaves (bd-9iv4qd).

  `Arbiter.Tasks.Issue.Changes.CleanupWorktree` reclaims a task's worktree on
  close, but a leaf whose git metadata is already gone falls outside anything
  keyed to a task: a `git worktree prune` (or a deleted scratch clone, as with
  `ext-review-*` checkouts of a `/tmp` clone) drops the metadata, `git worktree
  list` forgets the directory, and the seeded `_build`/`deps` shell sits under
  the root forever. This sweep removes exactly those — see
  `Arbiter.Worker.Worktree.orphaned_leaves/2` for the rule, which by
  construction never names a live worktree and never names a directory
  without a `.git` file (the root on a real box also holds database sockets
  and data directories nobody made a worktree of).

  Filesystem only: it never reads or writes the database, so unlike the
  session reapers it is not gated on being the primary instance — a second
  instance sweeping the same root finds the same dead leaves, or none.

  ## Configuration

  Via `config :arbiter, :worktree_sweeper`:

    * `:enabled`     — master switch (default `true`; `false` in test, where
                       tests call `sweep_once/1` directly).
    * `:interval_ms` — sweep cadence (default 3 600 000, one hour).
    * `:min_age_ms`  — how old a dead leaf's `.git` file must be before it is
                       removed (default one hour), so a leaf mid-creation is
                       never swept.
  """

  use GenServer

  require Logger

  alias Arbiter.Worker.Worktree

  @default_interval_ms 60 * 60_000
  @default_min_age_ms 60 * 60_000

  @type result :: %{removed: [Worktree.path()], failed: [{Worktree.path(), term()}]}

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Remove every dead leaf under the worktree root once.

  Options: `:root` (default `Arbiter.Config.Paths.worktree_root/0`),
  `:min_age_ms` (default from config).
  """
  @spec sweep_once(keyword()) :: result()
  def sweep_once(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &Arbiter.Config.Paths.worktree_root/0)
    min_age_ms = Keyword.get(opts, :min_age_ms, cfg(:min_age_ms, @default_min_age_ms))

    root
    |> Worktree.orphaned_leaves(min_age_ms: min_age_ms)
    |> Enum.reduce(%{removed: [], failed: []}, fn leaf, acc ->
      case File.rm_rf(leaf) do
        {:ok, _} ->
          Logger.info("WorktreeSweeper: removed #{leaf} (its gitdir no longer exists)")
          %{acc | removed: [leaf | acc.removed]}

        {:error, reason, file} ->
          Logger.warning(
            "WorktreeSweeper: could not remove #{leaf}: #{inspect(reason)} at #{file}"
          )

          %{acc | failed: [{leaf, reason} | acc.failed]}
      end
    end)
    |> then(&%{removed: Enum.reverse(&1.removed), failed: Enum.reverse(&1.failed)})
  end

  @doc "Run one sweep now, on the server, and return its result."
  @spec sweep_now(GenServer.server()) :: result()
  def sweep_now(server \\ __MODULE__), do: GenServer.call(server, :sweep_now, 60_000)

  # ---- GenServer callbacks -------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      enabled: cfg_opt(:enabled, opts, true),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms),
      min_age_ms: cfg_opt(:min_age_ms, opts, @default_min_age_ms)
    }

    if state.enabled, do: schedule(state.interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = safe_sweep(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:sweep_now, _from, state) do
    {:reply, safe_sweep(state), state}
  end

  defp safe_sweep(state) do
    sweep_once(min_age_ms: state.min_age_ms)
  rescue
    e ->
      Logger.warning("WorktreeSweeper: sweep failed: #{Exception.message(e)}")
      %{removed: [], failed: []}
  end

  defp schedule(ms), do: Process.send_after(self(), :sweep, ms)

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case Keyword.get(Application.get_env(:arbiter, :worktree_sweeper, []), key) do
      nil -> default
      val -> val
    end
  end
end
