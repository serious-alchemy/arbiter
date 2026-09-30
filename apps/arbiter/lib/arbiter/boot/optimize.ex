defmodule Arbiter.Boot.Optimize do
  @moduledoc """
  Runs `PRAGMA optimize` on all configured SQLite repositories during boot.

  ## Why this exists (bd-2zjtca / bd-91rxi7)

  SQLite's query planner relies on table statistics collected by `ANALYZE`.
  `PRAGMA optimize` checks if any tables need analysis (or re-analysis) based on
  query patterns and updates statistics incrementally. Running it at boot
  and periodically ensures the query planner makes optimal index and scan choices
  without paying the cost of a full database-wide `ANALYZE`.

  ## Supervision

  Mirrors `Arbiter.Boot.Migrator`: a one-shot synchronous worker that returns
  `:ignore`, gated on `Arbiter.SingleInstance.primary?/0` so a duplicate or
  secondary instance does not run optimization concurrently. It runs after
  `Arbiter.Boot.Migrator` so the schema is fully migrated before analyzing tables.
  """

  require Logger

  alias Arbiter.SingleInstance

  @doc """
  Child spec for the supervision tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Run `PRAGMA optimize` across all configured repos if primary and enabled.
  Returns `:ignore`.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    enabled? =
      case Keyword.fetch(opts, :enabled) do
        {:ok, val} -> val
        :error -> Application.get_env(:arbiter, :db_optimize, []) |> Keyword.get(:enabled, true)
      end

    primary? = Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0)

    cond do
      not enabled? ->
        Logger.info("Boot.Optimize: disabled — skipping PRAGMA optimize")

      not primary? ->
        Logger.info("Boot.Optimize: not the primary instance — skipping PRAGMA optimize")

      true ->
        run()
    end

    :ignore
  end

  @doc """
  Execute `PRAGMA optimize` on all configured repos.
  Logs results and catches any errors.
  """
  @spec run() :: :ok
  def run do
    repos = Application.get_env(:arbiter, :ecto_repos, [Arbiter.Repo])

    for repo <- repos do
      case repo.query("PRAGMA optimize") do
        {:ok, result} ->
          Logger.info(
            "Boot.Optimize: PRAGMA optimize ran successfully on #{inspect(repo)}: #{inspect(result.rows)}"
          )

        {:error, reason} ->
          Logger.warning(
            "Boot.Optimize: PRAGMA optimize failed on #{inspect(repo)}: #{inspect(reason)}"
          )
      end
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "Boot.Optimize: PRAGMA optimize encountered exception: #{Exception.message(e)}"
      )

      :ok
  end
end
