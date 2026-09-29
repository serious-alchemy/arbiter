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
