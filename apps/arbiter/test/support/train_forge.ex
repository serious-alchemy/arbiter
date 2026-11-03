defmodule Arbiter.Test.TrainForge do
  @moduledoc """
  A git-backed forge for speculative merge-train tests (bd-6dyva0): a bare
  `origin`, a `seed` clone that plays the developers and the forge's own merge
  button, and the `repo` checkout Arbiter builds cars in (a workspace's
  `repo_paths` entry). Everything is real git, so a test can assert on the
  trees that land on `main`.
  """

  @type t :: %{origin: String.t(), seed: String.t(), repo: String.t()}

  @doc "Create the repositories under `dir`, with one commit on `main`."
  @spec new(String.t()) :: t()
  def new(dir) do
    origin = Path.join(dir, "origin.git")
    seed = Path.join(dir, "seed")
    repo = Path.join(dir, "repo")

    git!(dir, ["init", "--bare", "--initial-branch=main", origin])
    git!(dir, ["clone", origin, seed])
    configure(seed)
    File.write!(Path.join(seed, "base.txt"), "one\ntwo\nthree\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-m", "base"])
    git!(seed, ["push", "origin", "main"])

    git!(dir, ["clone", origin, repo])
    configure(repo)

    %{origin: origin, seed: seed, repo: repo}
  end

  @doc "An MR branch off the current `main` adding `file`; returns its head."
  @spec branch!(t(), String.t(), String.t(), String.t()) :: String.t()
  def branch!(forge, name, file, content) do
    sync_main(forge)
    git!(forge.seed, ["checkout", "-b", name])
    File.write!(Path.join(forge.seed, file), content)
    git!(forge.seed, ["add", "."])
    git!(forge.seed, ["commit", "-m", "work on #{name}"])
    git!(forge.seed, ["push", "origin", name])
    head = git!(forge.seed, ["rev-parse", "HEAD"])
    git!(forge.seed, ["checkout", "main"])
    head
  end

  @doc "Push one more commit onto `branch` (an authored push); returns the new head."
  @spec push_to!(t(), String.t(), String.t(), String.t()) :: String.t()
  def push_to!(forge, branch, file, content) do
    git!(forge.seed, ["fetch", "origin", branch])
    git!(forge.seed, ["checkout", "-B", branch, "origin/" <> branch])
    File.write!(Path.join(forge.seed, file), content)
    git!(forge.seed, ["add", "."])
    git!(forge.seed, ["commit", "-m", "more on #{branch}"])
    git!(forge.seed, ["push", "origin", branch])
    head = git!(forge.seed, ["rev-parse", "HEAD"])
    git!(forge.seed, ["checkout", "main"])
    head
  end

  @doc "A commit straight onto `main` (another team's merge, a hotfix)."
  @spec advance_main!(t(), String.t(), String.t()) :: String.t()
  def advance_main!(forge, file, content) do
    sync_main(forge)
    File.write!(Path.join(forge.seed, file), content)
    git!(forge.seed, ["add", "."])
    git!(forge.seed, ["commit", "-m", "main moves: #{file}"])
    git!(forge.seed, ["push", "origin", "main"])
    git!(forge.seed, ["rev-parse", "HEAD"])
  end

  @doc """
  What a forge's merge-commit merge does: `main` gets a merge commit of its tip
  and `sha` (the MR head the merge was guarded on). Returns the merge commit.
  """
  @spec merge!(t(), String.t()) :: String.t()
  def merge!(forge, sha) do
    sync_main(forge)
    git!(forge.seed, ["fetch", "origin", sha])
    git!(forge.seed, ["merge", "--no-ff", "--no-edit", sha])
    git!(forge.seed, ["push", "origin", "main"])
    git!(forge.seed, ["rev-parse", "HEAD"])
  end

  @doc """
  A forged car in the `repo` checkout: `car`'s parents, but a tree carrying
  `file` besides the merge — content no reviewer saw. Returns `{sha, tree}`.
  """
  @spec forge_car!(t(), map(), String.t(), String.t()) :: {String.t(), String.t()}
  def forge_car!(forge, car, file, content) do
    index = Path.join(forge.repo, ".git/forged-index")
    env = [{"GIT_INDEX_FILE", index}]
    blob_path = Path.join(forge.repo, ".git/forged-blob")
    File.write!(blob_path, content)

    {_, 0} = System.cmd("git", ["-C", forge.repo, "read-tree", car.sha], env: env)
    blob = git!(forge.repo, ["hash-object", "-w", blob_path])

    {_, 0} =
      System.cmd(
        "git",
        ["-C", forge.repo, "update-index", "--add", "--cacheinfo", "100644,#{blob},#{file}"],
        env: env
      )

    {tree, 0} = System.cmd("git", ["-C", forge.repo, "write-tree"], env: env)
    tree = String.trim(tree)
    File.rm(index)
    File.rm(blob_path)

    sha =
      git!(forge.repo, ["commit-tree", tree, "-p", car.base, "-p", car.mr_head, "-m", "forged"])

    {sha, tree}
  end

  @doc "The sha `ref` (a branch name) points at on `origin`, or nil."
  @spec head(t(), String.t()) :: String.t() | nil
  def head(forge, ref) do
    case System.cmd("git", ["-C", forge.origin, "rev-parse", "--verify", "refs/heads/" <> ref],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  @doc "The tree of `rev` in `origin`."
  @spec tree(t(), String.t()) :: String.t()
  def tree(forge, rev), do: git!(forge.origin, ["rev-parse", rev <> "^{tree}"])

  @doc "The parents of commit `sha` in `origin`."
  @spec parents(t(), String.t()) :: [String.t()]
  def parents(forge, sha) do
    [^sha | parents] =
      forge.origin |> git!(["rev-list", "--parents", "-n", "1", sha]) |> String.split()

    parents
  end

  @doc "Is `ancestor` contained in `descendant` (in `origin`)?"
  @spec contains?(t(), String.t(), String.t()) :: boolean()
  def contains?(forge, descendant, ancestor) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", forge.origin, "merge-base", "--is-ancestor", ancestor, descendant],
        stderr_to_stdout: true
      )
    )
  end

  defp sync_main(forge) do
    git!(forge.seed, ["checkout", "main"])
    git!(forge.seed, ["pull", "--ff-only", "origin", "main"])
  end

  defp configure(path) do
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "commit.gpgsign", "false"])
  end

  defp git!(cd, args) do
    case System.cmd("git", args, cd: cd, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end
end
