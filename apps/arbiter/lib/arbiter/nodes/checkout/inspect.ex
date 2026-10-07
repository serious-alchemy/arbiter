defmodule Arbiter.Nodes.Checkout.Inspect do
  @moduledoc """
  Reading a git tree without checking it out (`docs/design/remote-workers.md` §9,
  RW2 U7): the path filter, the vetoes and the untracked-size cap are all
  decided from `ls-tree` on a bare repo, so nothing a snapshot carries is ever
  materialised before it has been judged.

  An *entries* map is `%{path => %{mode, sha, size}}` for every blob, symlink and
  gitlink in a tree.

  The same code runs on the node (before it uploads) and on the primary (the
  authoritative copy), so the two cannot drift.
  """

  alias Arbiter.Nodes.Checkout.Git
  alias Arbiter.Worker.Worktree

  @type entry :: %{mode: String.t(), sha: String.t(), size: non_neg_integer()}
  @type entries :: %{String.t() => entry()}

  # Candidates for the LFS pointer check: a pointer file is ~130 bytes and the
  # spec caps it at 1 KiB. Past this many candidates the scan stops (the
  # `.gitattributes` check is the primary signal; this one is a backstop).
  @pointer_max_bytes 1024
  @pointer_scan_cap 5_000
  @lfs_pointer "version https://git-lfs.github.com/spec/v1"

  @doc "The entries of `rev`'s tree in `git_dir` (empty for a `nil` rev)."
  @spec entries(Path.t(), String.t() | nil) :: {:ok, entries()} | {:error, term()}
  def entries(_git_dir, nil), do: {:ok, %{}}

  def entries(git_dir, rev) do
    with {:ok, out} <- Git.run(["ls-tree", "-r", "-z", "-l", "--full-tree", rev], git_dir: git_dir) do
      {:ok, parse(out)}
    end
  end

  # `<mode> SP <type> SP <sha> SP+ <size or -> TAB <path> NUL`
  defp parse(out) do
    for record <- String.split(out, <<0>>, trim: true),
        [meta, path] <- [String.split(record, "\t", parts: 2)],
        [mode, _type, sha, size] <- [String.split(meta, ~r/\s+/, trim: true)],
        into: %{} do
      {path, %{mode: mode, sha: sha, size: parse_size(size)}}
    end
  end

  defp parse_size("-"), do: 0
  defp parse_size(size), do: String.to_integer(size)

  @doc """
  Paths in `entries` the primary refuses to take back: the `Worktree`
  exclude set, plus `extra` (a run's recorded seeded paths, each a path or a
  directory prefix). A path whose mode and blob are identical in `trusted`
  (the primary's own base) is kept: that is content the primary already has.
  """
  @spec denied(entries(), entries(), [String.t()]) :: [String.t()]
  def denied(entries, trusted, extra \\ []) do
    prefixes = Enum.map(extra, &String.trim(&1, "/"))

    entries
    |> Enum.filter(fn {path, entry} ->
      (Worktree.excluded_checkout_path?(path) or under_any?(path, prefixes)) and
        not same?(trusted[path], entry)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp under_any?(path, prefixes),
    do: Enum.any?(prefixes, &(&1 != "" and (path == &1 or String.starts_with?(path, &1 <> "/"))))

  defp same?(%{mode: m, sha: s}, %{mode: m, sha: s}), do: true
  defp same?(_, _), do: false

  @doc """
  `:ok`, or `{:error, {:veto, kind, detail}}` for a tree a node cannot carry
  (bd-aowisc §4.4): a submodule (a gitlink entry or a `.gitmodules`) or Git LFS
  (a `.gitattributes` with `filter=lfs`, or a pointer blob among the paths that
  differ from `before`).
  """
  @spec veto(Path.t(), entries(), entries()) :: :ok | {:error, {:veto, atom(), String.t()}}
  def veto(git_dir, entries, before \\ %{}) do
    with :ok <- submodules(entries) do
      lfs(git_dir, entries, before)
    end
  end

  defp submodules(entries) do
    case Enum.find(entries, fn {path, %{mode: mode}} ->
           mode == "160000" or Path.basename(path) == ".gitmodules"
         end) do
      nil -> :ok
      {path, _} -> {:error, {:veto, :submodule, path}}
    end
  end

  defp lfs(git_dir, entries, before) do
    with :ok <- lfs_attributes(git_dir, entries) do
      lfs_pointers(git_dir, entries, before)
    end
  end

  defp lfs_attributes(git_dir, entries) do
    entries
    |> Enum.filter(fn {path, %{mode: mode}} ->
      Path.basename(path) == ".gitattributes" and mode in ["100644", "100755"]
    end)
    |> Enum.find_value(:ok, fn {path, %{sha: sha}} ->
      case Git.run(["cat-file", "blob", sha], git_dir: git_dir) do
        {:ok, body} -> if body =~ ~r/filter\s*=\s*lfs\b/, do: {:error, {:veto, :lfs, path}}
        _ -> nil
      end
    end)
  end

  defp lfs_pointers(git_dir, entries, before) do
    entries
    |> Enum.filter(fn {path, %{mode: mode, sha: sha, size: size}} ->
      mode in ["100644", "100755"] and size > 0 and size <= @pointer_max_bytes and
        before[path][:sha] != sha
    end)
    |> Enum.take(@pointer_scan_cap)
    |> Enum.find_value(:ok, fn {path, %{sha: sha}} ->
      case Git.run(["cat-file", "blob", sha], git_dir: git_dir) do
        {:ok, @lfs_pointer <> _} -> {:error, {:veto, :lfs, path}}
        _ -> nil
      end
    end)
  end

  @doc """
  Bytes of files `after_entries` has that `before` has no path for: the
  untracked (or newly added) payload of a snapshot. Symlinks and gitlinks count
  as their (tiny) object size.
  """
  @spec added_bytes(entries(), entries()) :: non_neg_integer()
  def added_bytes(after_entries, before) do
    for {path, %{size: size}} <- after_entries, not Map.has_key?(before, path), reduce: 0 do
      acc -> acc + size
    end
  end
end
