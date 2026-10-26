defmodule Arbiter.Worker.CliFetcher.Status do
  @moduledoc """
  The CLI fetcher as the doctor reports it (`GET /api/server/cli_versions`):
  per CLI the pinned version, the latest version upstream last reported, whether
  the pinned bytes are in the verified cache, whether the pin is `manual`, and the
  last `cli_version_bumped` row; plus the `worker.cli_set.hold` token and when the
  daily job last ran.

  Reads settings, the audit table, the local cache and the scheduler's last
  report. It never touches the network: the "latest" it shows is whatever the
  scheduler saw on its last run.

  Option `:scheduler_status` replaces the scheduler read (tests).
  """

  alias Arbiter.Settings
  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Scheduler

  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    scheduler = Keyword.get_lazy(opts, :scheduler_status, &Scheduler.status/0)
    manual = Settings.worker_cli_manual() || []
    latest = Map.get(scheduler, :latest, %{})

    %{
      hold: Settings.worker_cli_set_hold(),
      scheduler: %{
        enabled: Map.get(scheduler, :enabled, false),
        checked_at: iso(Map.get(scheduler, :checked_at))
      },
      clis: Enum.map(CliFetcher.names(), &cli(&1, latest, manual, opts))
    }
  end

  defp cli(name, latest, manual, opts) do
    pinned = CliFetcher.pin(name, opts)

    %{
      name: name,
      pinned: pinned,
      latest: Map.get(latest, name),
      cached: pinned != nil and match?({:ok, _}, Cache.lookup(name, pinned, opts)),
      manual: name in manual,
      last_bump: last_bump(name)
    }
  end

  defp last_bump(name) do
    case Enum.find(Settings.cli_version_events(cli: name), &(&1.kind == "cli_version_bumped")) do
      nil -> nil
      event -> %{from: event.from_version, to: event.to_version, at: iso(event.at)}
    end
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil
end
