defmodule Arbiter.Test.GitFixture do
  @moduledoc """
  Real git repositories for tests that need a task's local checkout.

  `origin_and_clone/0` builds an `origin` repo on `main` plus a `clone` of it
  whose `origin` remote points back at it — the shape of a workspace
  `repo_paths` checkout. Commits made in `origin` after the clone exist only
  upstream until the clone fetches them, which is the case a PR head pushed
  from elsewhere presents.

  The root directory is private to the calling test and removed on exit: /tmp
  is shared between concurrently running suites, so the name carries the OS
  pid as well as a unique integer.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "An `origin` repo (one commit on `main`) and a clone of it."
  @spec origin_and_clone(%{String.t() => String.t()}) :: %{
          root: String.t(),
          origin: String.t(),
          clone: String.t()
        }
  def origin_and_clone(files \\ %{"README.md" => "readme\n"}) do
    root =
      Path.join(
        System.tmp_dir!(),
        "gitfx-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    origin = Path.join(root, "origin")
    clone = Path.join(root, "clone")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", "-q", "-b", "main", origin])
    configure!(origin)
    commit!(origin, files, "init")

    git!(root, ["clone", "-q", origin, clone])
    configure!(clone)

    %{root: root, origin: origin, clone: clone}
  end

  @doc """
  A bare `forge` repo (one commit on `main`) and a `checkout` cloned from it
  whose `origin` is the forge — a workspace `repo_paths` checkout whose remote
  accepts pushes to any branch, `main` included. `seed` is a second clone that
  pushes to the forge, to move upstream on behind the checkout's back. Also
  points the worktree root at `<root>/worktrees` for the test, restoring the
  previous value on exit.

  `parent:` puts the root somewhere other than `System.tmp_dir!()` (the bwrap
  jail mounts a private tmpfs over `/tmp`, hiding anything under it).
  """
  @spec forge_and_checkout(%{String.t() => String.t()}, keyword()) :: %{
          root: String.t(),
          forge: String.t(),
          checkout: String.t(),
          worktree_root: String.t(),
          seed: String.t()
        }
  def forge_and_checkout(files \\ %{"README.md" => "readme\n"}, opts \\ []) do
    root =
      Path.join(
        Keyword.get_lazy(opts, :parent, &System.tmp_dir!/0),
        "gitfx-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    forge = Path.join(root, "forge.git")
    seed = Path.join(root, "seed")
    checkout = Path.join(root, "checkout")
    worktree_root = Path.join(root, "worktrees")
    File.mkdir_p!(seed)
    File.mkdir_p!(worktree_root)
    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", "-q", "--bare", "-b", "main", forge])
    git!(root, ["init", "-q", "-b", "main", seed])
    configure!(seed)
    commit!(seed, files, "init")
    git!(seed, ["remote", "add", "origin", forge])
    git!(seed, ["push", "-q", "origin", "main"])

    git!(root, ["clone", "-q", forge, checkout])
    configure!(checkout)

    prior = Application.fetch_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, worktree_root)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbiter, :worktree_root, value)
        :error -> Application.delete_env(:arbiter, :worktree_root)
      end
    end)

    %{root: root, forge: forge, checkout: checkout, worktree_root: worktree_root, seed: seed}
  end

  @doc """
  Write (or, for a `:delete` value, remove) `files` in `repo`'s working tree
  and commit them. Returns the new commit's sha.
  """
  @spec commit!(String.t(), %{String.t() => String.t() | :delete}, String.t()) :: String.t()
  def commit!(repo, files, message) do
    Enum.each(files, fn
      {path, :delete} ->
        git!(repo, ["rm", "-q", path])

      {path, content} ->
        full = Path.join(repo, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        git!(repo, ["add", path])
    end)

    git!(repo, ["commit", "-q", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  @doc "Run git in `repo`, raising on a non-zero exit. Returns trimmed output."
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  defp configure!(repo) do
    git!(repo, ["config", "user.email", "fixture@example.com"])
    git!(repo, ["config", "user.name", "fixture"])
    git!(repo, ["config", "commit.gpgsign", "false"])
  end
end
