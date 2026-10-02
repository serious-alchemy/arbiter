defmodule Arbiter.Worker.RunTmp.Sweeper do
  @moduledoc """
  Boot-time sweep of orphaned per-run temp dirs (bd-5ad4ch): runs that died
  with the server never reached `Arbiter.Worker.terminate/2`, so their
  `Arbiter.Worker.RunTmp` directory is still there. Removes those older than
  `config :arbiter, :run_tmp_sweeper, max_age_ms:` (default one day).
  Disabled in test, where tests call `Arbiter.Worker.RunTmp.sweep/1`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Arbiter.Worker.RunTmp

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    cfg = Application.get_env(:arbiter, :run_tmp_sweeper, [])

    if Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true)) do
      {:ok, Keyword.merge(cfg, opts), {:continue, :sweep}}
    else
      :ignore
    end
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep_opts = Keyword.take(state, [:max_age_ms, :root])

    try do
      case RunTmp.sweep(sweep_opts) do
        [] -> :ok
        removed -> Logger.info("RunTmp.Sweeper: removed #{length(removed)} orphaned temp dir(s)")
      end
    rescue
      e -> Logger.warning("RunTmp.Sweeper: sweep failed: #{Exception.message(e)}")
    end

    {:stop, :normal, state}
  end
end
