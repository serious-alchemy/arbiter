defmodule Arbiter.Worker.CliFetcher.Semver do
  @moduledoc """
  The only version syntax the CLI fetcher accepts: a plain `major.minor.patch`.

  Anything else (a `-alpha.1` prerelease, codex's `-linux-x64` platform
  variants, `+build` metadata, a leading `v`) is not "stable", so a bump can
  never land on it (`Arbiter.Worker.CliFetcher.Bump`).
  """

  @stable ~r/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

  @spec stable?(term()) :: boolean()
  def stable?(version) when is_binary(version), do: Regex.match?(@stable, version)
  def stable?(_), do: false

  @doc "The numerically newest stable version of the list, or `nil`."
  @spec newest_stable([term()]) :: String.t() | nil
  def newest_stable(versions) do
    versions |> Enum.filter(&stable?/1) |> Enum.max_by(&key/1, fn -> nil end)
  end

  @doc "True when stable version `a` is strictly newer than stable version `b`."
  @spec newer?(String.t(), String.t()) :: boolean()
  def newer?(a, b), do: key(a) > key(b)

  defp key(version) do
    [major, minor, patch] =
      @stable |> Regex.run(version, capture: :all_but_first) |> Enum.map(&String.to_integer/1)

    {major, minor, patch}
  end
end
