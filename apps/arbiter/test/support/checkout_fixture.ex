defmodule Arbiter.Test.CheckoutFixture do
  @moduledoc """
  Fixture repos for the node checkout-sync tests (RW11, `docs/design/remote-workers.md`
  §9): plain `git` on throwaway directories, with the user's own git config ignored.

  `home!/1` builds the primary's side: a repo with the awkward tree entries the
  round trip has to keep (an executable, relative/absolute/dangling symlinks, a
  unicode+space name, a file to rename and one to delete), `main` plus the run
  branch `arbiter/run` checked out at the same commit.
  """

  import ExUnit.Assertions

  @env [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

  @spec git!(Path.t(), [String.t()], keyword()) :: String.t()
  def git!(dir, args, env \\ []) do
    case git(dir, args, env) do
      {out, 0} -> String.trim_trailing(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} (#{code}) in #{dir}:\n#{out}")
    end
  end

  @spec git(Path.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def git(dir, args, env \\ []),
    do: System.cmd("git", args, cd: dir, env: @env ++ env, stderr_to_stdout: true)

  @spec commit_all!(Path.t(), String.t()) :: String.t()
  def commit_all!(dir, message) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  @spec init_repo!(Path.t()) :: Path.t()
  def init_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "fixture@example.com"])
    git!(dir, ["config", "user.name", "fixture"])
    dir
  end

  @doc "The primary's home clone, on branch `arbiter/run`, with the awkward tree entries."
  @spec home!(Path.t()) :: %{home: Path.t(), base: String.t()}
  def home!(tmp) do
    home = init_repo!(Path.join(tmp, "home"))
    File.mkdir_p!(Path.join(home, "bin"))
    File.mkdir_p!(Path.join(home, "lib"))
    File.write!(Path.join(home, "bin/run.sh"), "#!/bin/sh\necho hi\n")
    File.chmod!(Path.join(home, "bin/run.sh"), 0o755)

    File.write!(
      Path.join(home, "lib/a.txt"),
      Enum.map_join(1..40, "", &"content line #{&1} of the file to rename\n")
    )

    File.write!(Path.join(home, "lib/gone.txt"), "gone\n")
    File.write!(Path.join(home, "lib/keep.txt"), "keep\n")
    File.write!(Path.join(home, "weird name é.txt"), "unicode + space\n")
    File.ln_s!("lib/a.txt", Path.join(home, "link.txt"))
    File.ln_s!("/etc/passwd", Path.join(home, "abs-link"))
    File.ln_s!("nonexistent", Path.join(home, "dangling"))
    base = commit_all!(home, "base")
    git!(home, ["checkout", "-q", "-b", "arbiter/run"])
    %{home: home, base: base}
  end

  @doc "What a directory looks like: `%{path => {:file, exec?} | {:symlink, target} | :dir}`, `.git` excluded."
  @spec modes(Path.t()) :: map()
  def modes(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        not String.contains?(path, "/.git/"),
        not String.ends_with?(path, "/.git"),
        into: %{} do
      {:ok, st} = File.lstat(path)
      rel = Path.relative_to(path, dir)

      case st.type do
        :symlink -> {rel, {:symlink, File.read_link!(path)}}
        :regular -> {rel, {:file, Bitwise.band(st.mode, 0o111) != 0}}
        :directory -> {rel, :dir}
      end
    end
  end

  @doc """
  A commit whose tree holds `path_parts` (e.g. `[".git", "config"]`) -- written as
  raw objects, because `git add` refuses it. Returns the commit sha; `parent` may be nil.
  """
  @spec raw_commit!(Path.t(), [String.t()], String.t(), String.t() | nil, Path.t()) :: String.t()
  def raw_commit!(repo, path_parts, content, parent, scratch) do
    write = fn type, body ->
      file = Path.join(scratch, "raw-#{System.unique_integer([:positive])}")
      File.write!(file, body)
      git!(repo, ["hash-object", "-w", "-t", type, "--literally", file])
    end

    raw = &Base.decode16!(&1, case: :lower)
    blob = write.("blob", content)

    {tree, _} =
      path_parts
      |> Enum.reverse()
      |> Enum.reduce({blob, :blob}, fn name, {sha, kind} ->
        mode = if kind == :blob, do: "100644", else: "40000"
        {write.("tree", "#{mode} #{name}\0" <> raw.(sha)), :tree}
      end)

    parents = if parent, do: ["-p", parent], else: []
    git!(repo, ["commit-tree", "-m", "raw"] ++ parents ++ [tree])
  end
end
