defmodule Arbiter.Sessions.Memory do
  @moduledoc """
  Mounts the RFC §9.4 shared memory layers into a session's `memory/shared/`
  (bd-6dkpf1, phase 12 — depends on phase 3's scaffold).

  Per the operator's decision (Amendment 3, "a stale memory is worse", bd-cyxzvq),
  a session mounts memory **scoped by `metadata.type`**:

    * `user`, `feedback`, `reference` — mounted read-only for **every**
      session, regardless of workspace binding. Behavioural/operator context
      that doesn't rot and isn't specific to one repo.
    * `project` — mounted **only** for the session's bound workspace. A
      session bound to one workspace must not see another workspace's
      `project` memories (a vstim session must not load arbiter internals) —
      and a cross-workspace session (`workspace_id: nil`) gets none at all,
      since there is no single workspace to scope them to.

  ## Source layout

  `memory_root` (`Arbiter.Config.Paths.memory_root/0` by default) holds flat
  `*.md` files, each with a frontmatter block:

      ---
      name: some-slug
      description: ...
      metadata:
        type: user | feedback | reference | project
        workspace_id: <id>   # project only; which workspace this belongs to
      ---

  This mirrors the memory convention already in use for operator/worker
  memory elsewhere in this install — `type` and (for `project`)
  `workspace_id` are the only two fields this module reads; everything else
  in the file is opaque to it.

  ## Mount mechanism

  A symlink per file is sufficient — the RFC's read-only guarantee is a
  convention enforced by the generated `CLAUDE.md`
  (`Arbiter.Sessions.Instructions`), not a filesystem permission, since a
  session's own user can write through a symlink same as any other file it
  owns. Mounted under `memory/shared/<type>/<basename>`, so "type-scoped"
  is visible in the tree, not just in the filter that built it.

  `mount/2` fully re-renders `memory/shared/` on every call, the same way
  `Arbiter.Sessions.Provisioning` re-renders `CLAUDE.md` and `settings.json`
  on every provision — so a re-provision picks up memory that changed (or
  was removed) since the session first launched, and a source file deleted
  since the last mount does not leave a dangling symlink behind. Never
  touches `memory/candidates/` — that is the session's own write space and
  outlives re-provisioning.

  ## Only verified memory is served (phase 13, bd-19qve3)

  A memory is mounted only when its stored staleness verdict
  (`Arbiter.Sessions.Memory.Verdicts`) was made for its exact current bytes
  and is not stale. `mount/2` **reads** that verdict and never verifies
  anything itself, so a launch never waits on git or the ledger: the
  verification runs in `Arbiter.Sessions.Memory.Checker`. A memory with no
  current verdict, because it is new, was edited, or was never checked, is
  left out and the checker is nudged, so it is served from the next mount
  after its check. Quarantined memories live under `quarantined/`, which is
  never read here (`Arbiter.Sessions.Memory.Quarantine`). The full design is in
  `docs/design/memory-promotion-queue.md`.
  """

  require Logger

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Verdicts
  alias Arbiter.Sessions.Session

  @shared_types ~w(user feedback reference)

  @doc """
  Mount `session`'s shared memory layers. Always returns `:ok` — a missing or
  unreadable `memory_root` mounts nothing rather than failing provisioning
  (memory is additive context, not a launch requirement).

  ## Options

    * `:memory_root` — override for `Arbiter.Config.Paths.memory_root/0`
      (how the test suite points this at a fixture directory without
      touching the operator's real memory).
  """
  @spec mount(Session.t(), keyword()) :: :ok
  def mount(%Session{} = session, opts \\ []) do
    root = Keyword.get(opts, :memory_root, Paths.memory_root())
    shared_dir = Layout.memory_shared_dir(session.id)

    _ = File.rm_rf(shared_dir)
    File.mkdir_p!(shared_dir)

    {servable, pending} =
      root
      |> source_files()
      |> Enum.map(fn path -> {path, read(path)} end)
      |> Enum.split_with(fn {path, contents} -> servable?(root, path, contents) end)

    if pending != [], do: Checker.request_check()

    by_type =
      servable
      |> Enum.map(fn {path, contents} -> {path, Frontmatter.fields(contents)} end)
      |> Enum.group_by(fn {_path, fm} -> fm["type"] end)

    Enum.each(@shared_types, fn type ->
      mount_type(shared_dir, type, paths(by_type, type))
    end)

    project_files =
      by_type |> Map.get("project", []) |> matching_project(session.workspace_id)

    mount_type(shared_dir, "project", project_files)

    :ok
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

  defp servable?(_root, _path, nil), do: false

  defp servable?(root, path, contents),
    do: Verdicts.servable?(root, Path.basename(path), contents)

  defp paths(by_type, type) do
    by_type |> Map.get(type, []) |> Enum.map(fn {path, _fm} -> path end)
  end

  defp mount_type(shared_dir, type, files) do
    dest_dir = Path.join(shared_dir, type)
    File.mkdir_p!(dest_dir)

    Enum.each(files, fn path ->
      dest = Path.join(dest_dir, Path.basename(path))

      case File.ln_s(path, dest) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Sessions.Memory: could not mount #{path} at #{dest}: #{inspect(reason)}"
          )
      end
    end)
  end

  defp matching_project(_files, nil), do: []

  defp matching_project(files, workspace_id) do
    files
    |> Enum.filter(fn {_path, fm} -> fm["workspace_id"] == workspace_id end)
    |> Enum.map(fn {path, _fm} -> path end)
  end

  @doc """
  The memory files the shared layer serves from: the regular top-level `*.md`
  files of `root` (`quarantined/` and the `.verdicts/` sidecars are never
  among them). `[]` for a missing or unreadable root.
  """
  @spec source_files(Path.t()) :: [Path.t()]
  def source_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.regular?/1)

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Replace `path` with `contents` in one step: write a sibling temp file, then
  rename it over the target, so no reader ever sees a half-written memory.
  """
  @spec write_file_atomic(Path.t(), iodata()) :: :ok | {:error, File.posix()}
  def write_file_atomic(path, contents) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}"
      )

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents),
         {:error, _} = error <- File.rename(tmp, path) do
      _ = File.rm(tmp)
      error
    end
  end
end
