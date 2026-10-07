defmodule ArbiterCli.ReleaseRepo do
  @moduledoc """
  Which GitHub `owner/repo` `arb server deploy` and `arb self-update` pull
  releases from.

  An operator should not have to export `ARB_RELEASE_REPO` in every shell for
  the release path to work, so the repo is resolved from, in order:

    1. `ARB_RELEASE_REPO` — an explicit override, always wins.
    2. The running server's own metadata — `release_repo` on `GET /api/version`
       (the repo the release was built from, or the one its update checker is
       configured with).
    3. The repo stamped into this escript at build time
       (`ArbiterCli.Version.release_repo/0`).

  There is deliberately no fourth, silent default: when nothing answers, the
  caller dies naming the three ways to supply one. The source is returned with
  the repo so the deploy output can say where it came from.
  """

  alias ArbiterCli.Client

  @type source :: :env | :server | :build

  @slug ~r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

  @spec resolve() :: {:ok, String.t(), source()} | :error
  def resolve do
    with :error <- from_env(),
         :error <- from_server() do
      from_build()
    end
  end

  @doc "Human-readable provenance, for the deploy output."
  @spec describe(source()) :: String.t()
  def describe(:env), do: "from ARB_RELEASE_REPO"
  def describe(:server), do: "from the running server's release metadata"
  def describe(:build), do: "from the repo this arb was built from"

  defp from_env do
    case System.get_env("ARB_RELEASE_REPO") do
      slug when is_binary(slug) and slug != "" -> {:ok, slug, :env}
      _ -> :error
    end
  end

  defp from_server do
    case Client.get("/api/version") do
      {:ok, %{"release_repo" => slug}} when is_binary(slug) ->
        if Regex.match?(@slug, slug), do: {:ok, slug, :server}, else: :error

      _ ->
        :error
    end
  end

  defp from_build do
    case build_repo() do
      slug when is_binary(slug) and slug != "" -> {:ok, slug, :build}
      _ -> :error
    end
  end

  # `false` in the process dictionary means "no build-time repo" (tests).
  defp build_repo do
    case Process.get(:bd2_build_release_repo) do
      nil -> ArbiterCli.Version.release_repo()
      false -> nil
      repo -> repo
    end
  end
end
