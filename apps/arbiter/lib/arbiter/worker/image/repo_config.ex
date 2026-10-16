defmodule Arbiter.Worker.Image.RepoConfig do
  @moduledoc """
  A repo's worker image settings (KH11, `docs/design/remote-workers.md` §20.9):
  `worker.repos.<repo>.image` deep-merged over a workspace-level `worker.image`,
  per-repo wins (the resolution `Arbiter.Worker.SeedPaths.effective/2` gives every
  per-repo `worker.*` key).

      {"worker": {"repos": {"vstim": {"image": {
        "source": "generated",       // auto (default) | containerfile | generated | prebuilt
        "ref": "…",                  // prebuilt only; per repo only
        "registry": "registry.example.com/vstim",
        "credentials_ref": "secret:KEY",
        "seed": "primary"            // primary (default) | image | none
      }}}}}

  `source: auto` is the behaviour before this block existed: the default branch's
  `.arbiter/Containerfile` when committed, else the generated toolchain image.
  A value that is not one of the above reads as the default
  (`ValidateConfig` refuses it on write; this is the read-side guard for a
  hand-edited row).

  Only `source` changes behaviour today (`Image.plan/3`). `registry`,
  `credentials_ref`, `seed` and `ref` are validated and resolved here for the
  per-repo registry and prebuilt work that follows (KH12, KH14).

  Every source pushes to `<registry>/<repo-slug>/worker` (`repository_name/1`):
  a repo never shares an image repository with another, so the catch-all
  `<registry>/worker` does not exist.
  """

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.SeedPaths

  @sources %{
    "auto" => :auto,
    "containerfile" => :containerfile,
    "generated" => :generated,
    "prebuilt" => :prebuilt
  }
  @seeds %{"primary" => :primary, "image" => :image, "none" => :none}

  @type t :: %{
          source: :auto | :containerfile | :generated | :prebuilt,
          ref: String.t() | nil,
          registry: String.t() | nil,
          credentials_ref: String.t() | nil,
          seed: :primary | :image | :none
        }

  @doc "The `image.source` values, as the config spells them."
  @spec sources() :: [String.t()]
  def sources, do: Map.keys(@sources)

  @doc "The `image.seed` values, as the config spells them."
  @spec seeds() :: [String.t()]
  def seeds, do: Map.keys(@seeds)

  @doc "The resolved image settings for `repo` in `workspace` (a `Workspace`, any config-bearing map, or `nil`)."
  @spec resolve(term(), String.t() | nil) :: t()
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    case SeedPaths.effective(worker, repo) do
      %{"image" => %{} = image} -> build(image)
      _ -> build(%{})
    end
  end

  def resolve(_workspace, _repo), do: build(%{})

  defp build(image) do
    %{
      source: enum(image["source"], @sources, :auto),
      ref: string(image["ref"]),
      registry: string(image["registry"]),
      credentials_ref: string(image["credentials_ref"]),
      seed: enum(image["seed"], @seeds, :primary)
    }
  end

  defp enum(value, allowed, default) when is_binary(value),
    do: Map.get(allowed, value, default)

  defp enum(_value, _allowed, default), do: default

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  @doc """
  `<repo-slug>/worker`: the repository (under the registry) `repo`'s images are
  pushed to. An unnamed repo is `custom/worker`, never a bare `worker`.
  """
  @spec repository_name(String.t() | nil) :: String.t()
  def repository_name(repo), do: Image.slug(repo || "") <> "/worker"
end
