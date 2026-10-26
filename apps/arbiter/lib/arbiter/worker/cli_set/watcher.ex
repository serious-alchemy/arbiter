defmodule Arbiter.Worker.CliSet.Watcher do
  @moduledoc """
  Eager republish when the CLI set moves (SI2, OD13, `docs/design/remote-workers.md`
  §21.9): a new upstream CLI should reach every node and pod promptly, not on the
  next dispatch of each repo.

  It looks at the set (`Arbiter.Worker.CliSet.resolve/1`) at boot, every 10
  minutes, and on SI1a's `cli_version_bumped` event (`Bump` rewrites
  `worker.cli.versions`, announced as `{:installation_settings_changed,
  :worker_cli_versions}`). When the set's content hash differs from the one it
  last republished for (or it has not republished yet this boot), it calls
  `Arbiter.Worker.Image.Publisher.ensure_ready/2` again for every repo in
  `Arbiter.Worker.Image.PublishLedger` that published within the last 14 days,
  so a repo nobody has used for a fortnight is left for its next dispatch.
  A bump with identical bytes moves nothing.

  While `worker.cli_set.hold` is set it does nothing: the held set is what is
  published, and the auto-bump is suspended (`Bump`).

  ## Options

  `:name`, `:interval_ms` (default 10 minutes), `:boot_delay_ms` (default 30
  seconds; `:infinity` skips the boot run), `:days` (default 14), `:publish`
  (`fn ctx -> result end`, default `Publisher.ensure_ready/1`; a test seam) and
  `:cli_opts`, `:ledger`, `:now`, passed through to the set resolver and the
  ledger. `config :arbiter, :cli_set_watcher, enabled: false` keeps it from
  starting (the test suite).
  """

  use GenServer

  alias Arbiter.Settings
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.Image.Publisher
  alias Arbiter.Worker.Image.PublishLedger

  require Logger

  @interval_ms :timer.minutes(10)
  @boot_delay_ms :timer.seconds(30)
  @days 14

  @type outcome ::
          :held
          | :unchanged
          | {:error, term()}
          | {:republished, [{term(), term()}]}

  def start_link(opts \\ []) do
    enabled? =
      Keyword.get_lazy(opts, :enabled, fn ->
        :arbiter |> Application.get_env(:cli_set_watcher, []) |> Keyword.get(:enabled, true)
      end)

    if enabled? do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
    else
      :ignore
    end
  end

  @doc "Look at the set now and republish if it moved; returns what happened."
  @spec run_now(GenServer.server()) :: outcome()
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now, :infinity)

  @impl true
  def init(opts) do
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Settings.topic())

    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    if interval != :infinity, do: :timer.send_interval(interval, :tick)

    case Keyword.get(opts, :boot_delay_ms, @boot_delay_ms) do
      :infinity -> :ok
      ms -> Process.send_after(self(), :tick, ms)
    end

    {:ok, %{opts: opts, last_hash: nil}}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {outcome, state} = check(state)
    {:reply, outcome, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> check() |> elem(1)}

  def handle_info({:installation_settings_changed, :worker_cli_versions}, state),
    do: {:noreply, state |> check() |> elem(1)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp check(%{opts: opts} = state) do
    with nil <- Settings.worker_cli_set_hold(),
         {:ok, set} <- CliSet.resolve(Keyword.get(opts, :cli_opts, [])) do
      if set.hash == state.last_hash do
        {:unchanged, state}
      else
        results = republish(opts)
        # Advance only when every republish succeeded, so a transient registry
        # failure is retried on the next tick.
        failed? = Enum.any?(results, &match?({_, {:error, _}}, &1))
        {{:republished, results}, if(failed?, do: state, else: %{state | last_hash: set.hash})}
      end
    else
      hold when is_binary(hold) -> {:held, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp republish(opts) do
    # `ledger: nil`: a republish must not record itself, or it would restart the
    # repo's 14-day clock and a repo nobody dispatches would never age out.
    publish = Keyword.get(opts, :publish, &Publisher.ensure_ready(&1, ledger: nil))
    ledger = Keyword.take(opts, [:ledger, :now])

    for %{key: key, ctx: ctx} <- PublishLedger.recent(Keyword.get(opts, :days, @days), ledger) do
      result =
        try do
          publish.(ctx)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:error, reason} ->
          Logger.warning(
            "CliSet.Watcher: republish of #{inspect(key)} failed: #{inspect(reason)}"
          )

        _ ->
          :ok
      end

      {key, result}
    end
  end
end
