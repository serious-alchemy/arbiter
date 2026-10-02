defmodule Arbiter.Sessions.Memory.Checker do
  @moduledoc """
  The staleness checker (bd-19qve3, RFC §9.4 phase 13), run **off the mount
  path** (amendment 3): it verifies the shared memory layer on its own
  schedule and persists one verdict per memory
  (`Arbiter.Sessions.Memory.Verdicts`). `Arbiter.Sessions.Memory.mount/2` only
  reads those verdicts, so a session launch never waits on git or on the
  ledger.

  ## A pass (`run/1`)

  For each top-level `*.md` in the memory root, the pass skips the memory if its
  stored verdict is still **current**. Otherwise it verifies the memory
  (`Arbiter.Sessions.Memory.Staleness`) and stores the new verdict. A `:stale`
  verdict is stored first, so the memory stops being served even if the next
  step fails, and then the memory is moved into quarantine
  (`Arbiter.Sessions.Memory.Quarantine`).

  A verdict is current while all of these hold:

    * it is `:ok`. An `:unverified` verdict is retried every pass, and a
      `:stale` one never survives a pass;
    * it was made for the memory's exact bytes;
    * every checkout it was made against is still at the same `HEAD`;
    * for `project` and `reference` memories only, it is younger than
      `:max_age_ms` (default 24h).

  That last rule is how decay tracks type. `project` and `reference` rot fast,
  so they are re-verified at least daily, even when no tracked checkout moved
  (a ticket or a workspace's repo list can change without a commit). `user`
  and `feedback` are behavioural. Their verdict lasts until their text, or the
  code their citations name, changes.

  ## The process

  Runs a pass `:initial_delay_ms` after boot, then every `:interval_ms`. A mount
  that finds memories with no current verdict calls `request_check/1`, a
  cast, debounced by `:debounce_ms`, so newly promoted or hand-edited memory is
  picked up within seconds rather than at the next tick.

  Via `config :arbiter, :memory_checker`:

    * `:enabled`          — master switch (default `true`; `false` in test,
                            where tests call `run/1` directly).
    * `:interval_ms`      — pass cadence (default 15 minutes).
    * `:initial_delay_ms` — first pass after boot (default 30 seconds).
    * `:debounce_ms`      — coalescing window for mount nudges (default 2s).
    * `:max_age_ms`       — verdict lifetime for `project`/`reference`
                            memories (default 24 hours).
  """

  use GenServer

  require Logger

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Memory.Quarantine
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts

  @behavioural ~w(user feedback)
  @default_interval_ms 15 * 60_000
  @default_initial_delay_ms 30_000
  @default_debounce_ms 2_000
  @default_max_age_ms 24 * 60 * 60_000

  @type summary :: %{
          verified: [String.t()],
          skipped: [String.t()],
          quarantined: [{String.t(), String.t()}],
          failed: [String.t()]
        }

  @doc """
  One pass over the shared memory layer. Returns which memories were verified
  (including any then quarantined), skipped as current, quarantined (as
  `{basename, quarantined_name}`), or could not be read.

  Takes `:memory_root`, `:max_age_ms` and `:now`, plus everything
  `Arbiter.Sessions.Memory.Staleness.verify_contents/2` accepts.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    root = Keyword.get(opts, :memory_root, Paths.memory_root())
    opts = Keyword.put_new(opts, :now, DateTime.utc_now())

    root
    |> Memory.source_files()
    |> Enum.reduce(
      %{verified: [], skipped: [], quarantined: [], failed: []},
      &check_one(root, &1, opts, &2)
    )
    |> Map.new(fn {key, list} -> {key, Enum.reverse(list)} end)
  end

  defp check_one(root, path, opts, summary) do
    basename = Path.basename(path)

    case File.read(path) do
      {:ok, contents} ->
        check_contents(root, basename, contents, opts, summary)

      {:error, reason} ->
        Logger.warning("Arbiter.Sessions.Memory.Checker: cannot read #{path}: #{inspect(reason)}")
        add(summary, :failed, basename)
    end
  end

  defp check_contents(root, basename, contents, opts, summary) do
    prior = Verdicts.read(root, basename)

    if current?(prior, contents, opts) do
      add(summary, :skipped, basename)
    else
      verdict =
        Staleness.verify_contents(contents, Keyword.put(opts, :anchors, prior_anchors(prior)))

      record(root, basename, verdict, add(summary, :verified, basename))
    end
  end

  defp current?({:ok, %{status: :ok} = verdict}, contents, opts) do
    verdict.content_sha256 == Staleness.content_hash(contents) and young?(verdict, opts) and
      Enum.all?(verdict.checked_against, fn {path, sha} -> Staleness.head_sha(path) == sha end)
  end

  defp current?(_prior, _contents, _opts), do: false

  defp young?(%{type: type}, _opts) when type in @behavioural, do: true

  defp young?(%{checked_at: checked_at}, opts) do
    max_age = Keyword.get(opts, :max_age_ms, cfg(:max_age_ms, @default_max_age_ms))
    DateTime.diff(Keyword.fetch!(opts, :now), checked_at, :millisecond) < max_age
  end

  # First-use anchors carry over by citation, so editing one line of a memory
  # does not reset the anchors of the citations it kept.
  defp prior_anchors({:ok, %{anchors: anchors}}), do: anchors
  defp prior_anchors(:none), do: %{}

  defp record(root, basename, verdict, summary) do
    with {:error, reason} <- Verdicts.write(root, basename, verdict) do
      Logger.error(
        "Arbiter.Sessions.Memory.Checker: cannot store verdict for #{basename}: #{inspect(reason)}"
      )
    end

    if verdict.status == :stale,
      do: quarantine(root, basename, verdict, summary),
      else: summary
  end

  defp quarantine(root, basename, verdict, summary) do
    case Quarantine.quarantine(root, basename, verdict) do
      {:ok, name} ->
        Logger.info(
          "Arbiter.Sessions.Memory.Checker: quarantined #{basename}: #{Enum.join(verdict.reasons, "; ")}"
        )

        add(summary, :quarantined, {basename, name})

      {:error, reason} ->
        Logger.error(
          "Arbiter.Sessions.Memory.Checker: could not quarantine #{basename}: #{inspect(reason)}"
        )

        add(summary, :failed, basename)
    end
  end

  defp add(summary, key, value), do: Map.update!(summary, key, &[value | &1])

  # ---- process ---------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Ask the checker for a pass soon. Never blocks and never fails: a checker that
  is not running, or is disabled, simply ignores it.
  """
  @spec request_check(GenServer.server()) :: :ok
  def request_check(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :request)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      enabled: opt(opts, :enabled, true),
      interval_ms: opt(opts, :interval_ms, @default_interval_ms),
      debounce_ms: opt(opts, :debounce_ms, @default_debounce_ms),
      run_opts: Keyword.get(opts, :run_opts, []),
      nudge: nil
    }

    if state.enabled,
      do:
        Process.send_after(self(), :run, opt(opts, :initial_delay_ms, @default_initial_delay_ms))

    {:ok, state}
  end

  @impl true
  def handle_cast(:request, %{enabled: false} = state), do: {:noreply, state}
  def handle_cast(:request, %{nudge: ref} = state) when is_reference(ref), do: {:noreply, state}

  def handle_cast(:request, %{debounce_ms: 0} = state) do
    run_safely(state)
    {:noreply, state}
  end

  def handle_cast(:request, state) do
    {:noreply, %{state | nudge: Process.send_after(self(), :nudge, state.debounce_ms)}}
  end

  @impl true
  def handle_info(:run, state) do
    run_safely(state)
    Process.send_after(self(), :run, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:nudge, state) do
    run_safely(state)
    {:noreply, %{state | nudge: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_safely(state) do
    run(state.run_opts)
  rescue
    e -> Logger.error("Arbiter.Sessions.Memory.Checker pass failed: #{Exception.message(e)}")
  end

  defp opt(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case Keyword.get(Application.get_env(:arbiter, :memory_checker, []), key) do
      nil -> default
      value -> value
    end
  end
end
