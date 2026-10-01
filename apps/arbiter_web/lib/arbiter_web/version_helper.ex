defmodule ArbiterWeb.VersionHelper do
  @moduledoc """
  Caches the Arbiter version string for efficient access in template renders.

  The version string is computed once at boot and stored in `:persistent_term`
  to avoid calling `Arbiter.Version` functions (which shell out to git) on
  every layout render.
  """

  @cache_key {:arbiter_web, :version_tooltip}

  @doc "Initialize the version cache at boot time."
  def init_cache do
    version = Arbiter.Version.app_version()
    sha = Arbiter.Version.git_sha()
    tooltip = "Arbiter v#{version} (#{sha})"
    :persistent_term.put(@cache_key, tooltip)
    tooltip
  end

  @doc "Get the cached version tooltip string."
  def get_tooltip do
    case :persistent_term.get(@cache_key, nil) do
      nil -> init_cache()
      tooltip -> tooltip
    end
  end
end
