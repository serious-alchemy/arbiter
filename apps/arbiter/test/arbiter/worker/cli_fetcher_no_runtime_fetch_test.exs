defmodule Arbiter.Worker.CliFetcherNoRuntimeFetchTest do
  @moduledoc """
  SI1a (OD13): "no network fetch at run time; only the publisher reads the
  cache". The fetcher's network surface is `Arbiter.Worker.CliFetcher.Upstream`
  (the only module that can open a connection), `CliFetcher.fetch/ensure/
  ensure_pinned/latest` and `CliFetcher.Bump`. This test fails if any code
  outside the fetcher's own namespace names them: a dispatch, spawn, publish or
  run path may only read `CliFetcher.Cache`, `Status`, `Semver` and the pure pin
  accessors.
  """
  use ExUnit.Case, async: true

  @namespace_dir "lib/arbiter/worker/cli_fetcher"
  @namespace_file "lib/arbiter/worker/cli_fetcher.ex"

  @network ~r/CliFetcher\.(Upstream|Bump)\b|CliFetcher\.(fetch|ensure|ensure_pinned|latest)\b/
  # The scheduler is the one entry point: it is started from the supervision tree.
  @scheduler_ref ~r/CliFetcher\.Scheduler\b/

  defp sources do
    for path <- Path.wildcard("../*/lib/**/*.ex"), do: {path, File.read!(path)}
  end

  defp inside?(path) do
    expanded = Path.expand(path)

    String.starts_with?(expanded, Path.expand(@namespace_dir) <> "/") or
      expanded == Path.expand(@namespace_file)
  end

  test "no module outside the fetcher can reach the network surface" do
    offenders =
      for {path, text} <- sources(), not inside?(path), Regex.match?(@network, text), do: path

    assert offenders == []
  end

  test "only the supervision tree starts the scheduler" do
    offenders =
      for {path, text} <- sources(),
          not inside?(path),
          Regex.match?(@scheduler_ref, text),
          Path.basename(path) not in ["application.ex", "status.ex"],
          do: path

    assert offenders == []
  end

  test "within the namespace only the facade talks to Upstream" do
    offenders =
      for {path, text} <- sources(),
          inside?(path),
          Path.basename(path) not in ["cli_fetcher.ex", "upstream.ex"],
          Regex.match?(~r/\bUpstream\b/, text),
          do: path

    assert offenders == []
  end

  test "the cache and the status read model never use an HTTP client" do
    for file <- ["cache.ex", "status.ex", "integrity.ex", "tarball.ex"] do
      text = File.read!(Path.join(@namespace_dir, file))
      refute text =~ ~r/\bReq\./, "#{file} must not use Req"
      refute text =~ ":httpc"
    end
  end

  test "the scan sees the real sources" do
    assert Enum.any?(sources(), fn {path, _} -> inside?(path) end)

    assert Enum.any?(sources(), fn {path, _} ->
             String.ends_with?(path, "worker/image/publisher.ex")
           end)
  end
end
