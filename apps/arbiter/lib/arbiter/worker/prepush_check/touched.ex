defmodule Arbiter.Worker.PrepushCheck.Touched do
  @moduledoc """
  The files a branch touched, for the `scope: touched` steps of the pre-push
  recipe (`Arbiter.Worker.PrepushCheck`): which files to lint, and which test
  files cover the changed modules.

  The diff is `git diff --name-only <merge-base> HEAD` against the task's
  target branch (`origin/<target>` first, then the local ref). Only files that
  still exist are returned — a deletion has nothing to lint or run. When the
  target cannot be resolved (no such ref, not a git checkout) the answer is
  `:unknown` and the caller runs the step unscoped rather than skipping it.
  """

  @doc "The existing files changed on HEAD since it left `target`, sorted."
  @spec files(String.t(), String.t() | nil) :: {:ok, [String.t()]} | :unknown
  def files(worktree, target) when is_binary(target) and target != "" do
    with {:ok, base} <- merge_base(worktree, target),
         {out, 0} <-
           git(worktree, ["diff", "--name-only", "-z", "--diff-filter=ACMR", base, "HEAD"]) do
      files =
        out
        |> String.split("\0", trim: true)
        |> Enum.filter(&File.regular?(Path.join(worktree, &1)))
        |> Enum.sort()

      {:ok, files}
    else
      _ -> :unknown
    end
  end

  def files(_worktree, _target), do: :unknown

  defp merge_base(worktree, target) do
    Enum.find_value(["origin/" <> target, target], :error, fn ref ->
      case git(worktree, ["merge-base", ref, "HEAD"]) do
        {out, 0} -> {:ok, String.trim(out)}
        _ -> nil
      end
    end)
  end

  # sobelow_skip ["CI.System"]
  defp git(worktree, args) do
    System.cmd("git", ["-C", worktree | args], stderr_to_stdout: true)
  rescue
    _ -> :error
  end

  @doc "The `.ex` / `.exs` members of `files`."
  @spec elixir_files([String.t()]) :: [String.t()]
  def elixir_files(files), do: Enum.filter(files, &(Path.extname(&1) in [".ex", ".exs"]))

  @doc """
  The Elixir files credo analyses: those `.credo.exs` includes (`lib/`,
  `apps/*/lib/`). Passing credo a file on the command line bypasses that filter,
  so a touched test file would be linted by a rule set CI never applies to it.
  """
  @spec credo_files([String.t()]) :: [String.t()]
  def credo_files(files) do
    files
    |> elixir_files()
    |> Enum.filter(&Regex.match?(~r{^(apps/[^/]+/)?lib/}, &1))
  end

  @doc """
  The test files to run for `files`: a changed `*_test.exs` itself, and for a
  changed `lib/<path>.ex` (at the repo root or under `apps/<app>/`) the
  `test/<path>_test.exs` beside it — when that file exists in `worktree`.
  """
  @spec test_files([String.t()], String.t()) :: [String.t()]
  def test_files(files, worktree) do
    files
    |> Enum.flat_map(&candidate_tests/1)
    |> Enum.filter(&File.regular?(Path.join(worktree, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp candidate_tests(file) do
    cond do
      String.ends_with?(file, "_test.exs") -> [file]
      Path.extname(file) != ".ex" -> []
      true -> lib_to_test(file)
    end
  end

  defp lib_to_test(file) do
    case Regex.run(~r{^((?:apps/[^/]+/)?)lib/(.+)\.ex$}, file) do
      [_, prefix, rest] -> [prefix <> "test/" <> rest <> "_test.exs"]
      _ -> []
    end
  end

  @doc """
  `test_files/2` without the existence check: the test paths `files` would map to,
  for a caller that checks them somewhere other than this host (a node's checkout).
  """
  @spec candidate_test_files([String.t()]) :: [String.t()]
  def candidate_test_files(files), do: files |> Enum.flat_map(&candidate_tests/1) |> Enum.uniq()

  @doc "`paths` as one shell word list, each single-quoted."
  @spec quote_args([String.t()]) :: String.t()
  def quote_args(paths), do: Enum.map_join(paths, " ", &shell_quote/1)

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
