defmodule Mix.Tasks.Arbiter.FetchClis do
  @shortdoc "Fetch and verify the pinned upstream claude/codex/arb into the CLI cache"
  @moduledoc """
  Fills the verified CLI cache (SI1a) now, so local and remote workers can run.

  ## Usage

      mix arbiter.fetch_clis

  Workers run only the cached, checksum-verified upstream CLIs
  (`Arbiter.Worker.CliSet`), never one installed on this host. The daily
  `Arbiter.Worker.CliFetcher.Scheduler` fills the cache itself where it is
  enabled (prod, dev); run this where it is off (`ARBITER_CLI_FETCHER=0`) or
  after wiping the cache. A CLI whose version is already cached costs no
  network. Exits non-zero when a pinned CLI could not be cached.

  It is a thin wrapper over `Arbiter.Release.fetch_clis/1`, which a release
  install runs as `bin/arbiter eval 'Arbiter.Release.fetch_clis()'`. It starts
  only Ash + the Ecto repo, never the full application.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.config")

    failed =
      for {name, {:error, _}} <- Arbiter.Release.fetch_clis(), do: name

    if failed != [], do: Mix.raise("not cached: #{Enum.join(Enum.sort(failed), ", ")}")
  end
end
