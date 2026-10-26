defmodule Arbiter.Worker.CliFetcher.Bump do
  @moduledoc """
  The automatic version bump (OD13: keep the CLIs as current as possible).

  For each pinned CLI (claude, codex), in order:

    1. `worker.cli_set.hold` set: nothing moves (`{:held, token}`), no download.
    2. The CLI is listed in `worker.cli.manual`: `:manual`.
    3. Ask upstream for the newest stable version
       (`Arbiter.Worker.CliFetcher.latest/2`: a plain `x.y.z`, never a prerelease).
       A pin already at or past it stays (`{:current, pin}`): a pin never moves
       backwards.
    4. Otherwise fetch and verify the newer version into the cache
       (`Arbiter.Worker.CliFetcher.ensure/3`). Only after it is verified and
       stored is the pin rewritten and a `cli_version_bumped` row appended
       (`Arbiter.Settings.record_cli_version_event/1`). A failed fetch leaves
       the pin and the audit trail untouched (`{:error, reason}`).

  Rewriting `worker.cli.versions` announces
  `{:installation_settings_changed, :worker_cli_versions}` on
  `Arbiter.Settings.topic/0`, which is what lets the CLI set (SI1/SI2) republish
  the images.

  Run by `Arbiter.Worker.CliFetcher.Scheduler` (daily, and on demand).
  """

  alias Arbiter.Settings
  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Semver

  require Logger

  @type result ::
          {:bumped, String.t() | nil, String.t()}
          | {:current, String.t()}
          | {:held, String.t()}
          | :manual
          | {:error, term()}

  @doc """
  Check every pinned CLI. Returns `%{name => result}`.
  """
  @spec run(keyword()) :: %{String.t() => result()}
  def run(opts \\ []) do
    opts |> check() |> Map.new(fn {name, %{action: action}} -> {name, action} end)
  end

  @doc """
  `run/1` with what upstream said: `%{name => %{latest: {:ok, version} | {:error, reason}, action: result}}`.
  The newest version is looked up even when a hold or a manual pin forbids the
  bump, so the doctor can show what is being held back.
  """
  @spec check(keyword()) :: %{
          String.t() => %{latest: {:ok, String.t()} | {:error, term()}, action: result()}
        }
  def check(opts \\ []) do
    Map.new(CliFetcher.pinned_names(), fn name ->
      latest = CliFetcher.latest(name, opts)
      {name, %{latest: latest, action: bump(name, latest, opts)}}
    end)
  end

  defp bump(name, latest, opts) do
    cond do
      hold = Settings.worker_cli_set_hold() -> {:held, hold}
      name in (Settings.worker_cli_manual() || []) -> :manual
      true -> bump_to_latest(name, latest, opts)
    end
  end

  defp bump_to_latest(name, latest, opts) do
    current = CliFetcher.pin(name)

    with {:ok, latest} <- latest,
         :ok <- newer_or_unpinned(current, latest),
         {:ok, entry} <- CliFetcher.ensure(name, latest, opts),
         {:ok, _} <- pin(name, latest) do
      record(name, current, latest, entry)
      Logger.info("CliFetcher: #{name} pin #{inspect(current)} -> #{latest}")
      {:bumped, current, latest}
    else
      {:current, version} -> {:current, version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp newer_or_unpinned(nil, _latest), do: :ok

  defp newer_or_unpinned(current, latest) do
    if Semver.newer?(latest, current), do: :ok, else: {:current, current}
  end

  defp pin(name, version) do
    Settings.set_worker_cli_versions(
      Map.put(Settings.worker_cli_versions() || %{}, name, version)
    )
  end

  defp record(name, from, to, entry) do
    case Settings.record_cli_version_event(%{
           kind: "cli_version_bumped",
           cli: name,
           from_version: from,
           to_version: to,
           detail: %{
             "integrity" => entry.integrity,
             "digest" => entry.digest,
             "source" => entry.source
           }
         }) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("CliFetcher: bump audit row not written: #{inspect(error)}")
    end
  end
end
