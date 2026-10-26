defmodule Arbiter.Worker.CliFetcher.Fill do
  @moduledoc """
  The operator-triggered cache fill (SI1a/SI1): fetch, checksum-verify and
  store every pinned upstream CLI that is not cached yet, once, on demand.

  It lives inside the fetcher's namespace because it is one of the few callers
  allowed to reach the network surface (`Arbiter.Worker.CliFetcher.ensure_pinned/1`);
  `Arbiter.Release.fetch_clis/1` and `mix arbiter.fetch_clis` delegate here
  rather than naming the facade themselves. No dispatch, spawn or publish path
  calls it.
  """

  @type outcome :: :ok | :unpinned | {:error, term()}

  @doc "Cache every pinned CLI (`opts` as `Arbiter.Worker.CliFetcher.ensure_pinned/1`); one line per CLI is printed."
  @spec run(keyword()) :: %{String.t() => outcome()}
  def run(opts \\ []) do
    result =
      Map.new(Arbiter.Worker.CliFetcher.ensure_pinned(opts), fn
        {name, {:ok, _entry}} -> {name, :ok}
        {name, other} -> {name, other}
      end)

    for {name, outcome} <- Enum.sort(result), do: IO.puts(line(name, outcome))
    result
  end

  defp line(name, :ok), do: "#{name}: cached"

  defp line(name, :unpinned),
    do: "#{name}: no version pinned (set worker.cli.versions; arb needs a stable release)"

  defp line(name, {:error, reason}), do: "#{name}: NOT cached: #{inspect(reason)}"
end
