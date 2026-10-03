defmodule ArbiterWeb.Api.ImageController do
  @moduledoc """
  REST endpoints for the worker image lifecycle (bd-9r5jdt): the transport
  behind `arb image list` / `build` / `refresh` / `prune`.

  Routes:

    * `GET  /api/images` — Arbiter's local dev images, the base-image digest
      pins, and whether the weekly refresh is due
    * `POST /api/images/build` — `repo` (a registered repo name) and optional
      `workspace`: plan the image from the repo's **default branch** and build
      what is missing (single-flight; returns once the tag exists)
    * `POST /api/images/refresh` — re-resolve every base pin now and prune
    * `POST /api/images/prune` — remove stale tags (newest two per name stay)

  A request can name a repo, never a branch or a path: the checkout and the
  default branch come from `Arbiter.Worker.Image.RepoSource`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.Image.Pins
  alias Arbiter.Worker.Image.RepoSource
  alias Arbiter.Worker.Image.Refresher

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, _params) do
    pins = Pins.load()

    with {:ok, images} <- image_list() do
      json(conn, %{
        podman: System.find_executable("podman") != nil,
        images: Enum.map(images, &serialize_image/1),
        pins:
          pins.pins
          |> Enum.sort()
          |> Enum.map(fn {ref, p} ->
            %{ref: ref, digest: p["digest"], resolved_at: p["resolved_at"]}
          end),
        refreshed_at: pins.refreshed_at,
        refresh_due: Pins.due?()
      })
    end
  end

  def build(conn, params) do
    with {:ok, source} <- source(params),
         {:ok, plan} <- plan(source),
         {:ok, built} <- ensure(plan) do
      json(conn, %{
        tag: built.tag,
        built: built.built,
        cached: built.built == [],
        name: plan.name,
        base_tag: plan.base.tag,
        source: plan.source,
        ref: plan.ref,
        default_branch: source.default_branch,
        toolchain: plan.toolchain,
        pins: Enum.map(plan.pins, fn {ref, digest} -> %{ref: ref, digest: digest} end)
      })
    end
  end

  def refresh(conn, _params) do
    case Refresher.run_now(Refresher, force: true) do
      {:ran, result} -> json(conn, serialize_refresh(result))
      :not_due -> json(conn, %{changed: [], failed: [], pruned: %{removed: [], failed: []}})
    end
  end

  def prune(conn, _params) do
    case Image.prune() do
      {:ok, result} -> json(conn, serialize_prune(result))
      {:error, message} -> {:error, {:conflict, message}}
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp image_list do
    case Image.list() do
      {:ok, images} -> {:ok, images}
      # No podman on this host: the page still shows the pins.
      {:error, _} -> {:ok, []}
    end
  end

  defp source(params) do
    case RepoSource.resolve(params["repo"], blank_to_nil(params["workspace"])) do
      {:ok, source} -> {:ok, source}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  defp plan(source) do
    case Image.plan(source.path, source.default_branch, repo_name: source.repo) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, {:invalid_request, "cannot plan image: #{describe(reason)}"}}
    end
  end

  defp ensure(plan) do
    case Builder.ensure(plan) do
      {:ok, built} -> {:ok, built}
      {:error, reason} -> {:error, {:conflict, "image build failed: #{describe(reason)}"}}
    end
  end

  defp describe({:build_failed, _tag, 127, _output}),
    do: "podman is not installed on this host (run `arb server doctor`)"

  defp describe({:build_failed, tag, status, output}),
    do: "podman build of #{tag} exited #{status}: #{output}"

  defp describe({:unpinned_base, ref, reason}),
    do: "base image #{ref} could not be pinned by digest (#{inspect(reason)})"

  defp describe({:no_default_branch, branch}),
    do: "default branch #{inspect(branch)} not found in the repo's checkout"

  defp describe(other), do: inspect(other)

  defp serialize_image(image) do
    Map.take(image, [:tag, :name, :hash, :kind, :id, :created, :size])
  end

  defp serialize_refresh(%{changed: changed, failed: failed, pruned: pruned}) do
    %{
      changed: Enum.map(changed, fn {ref, old, new} -> %{ref: ref, from: old, to: new} end),
      failed: Enum.map(failed, fn {ref, reason} -> %{ref: ref, reason: reason} end),
      pruned: serialize_prune(pruned)
    }
  end

  defp serialize_prune(%{removed: removed, failed: failed}) do
    %{
      removed: removed,
      failed: Enum.map(failed, fn {tag, reason} -> %{tag: tag, reason: reason} end)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
