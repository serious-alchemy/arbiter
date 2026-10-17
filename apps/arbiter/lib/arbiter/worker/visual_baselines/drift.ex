defmodule Arbiter.Worker.VisualBaselines.Drift do
  @moduledoc """
  "Is this visual failure only main's drift?" (bd-9obzu9, GitHub #936).

  A snapshot mismatch after syncing with main has two possible causes: main
  changed the page under the branch, or the branch's own work did. Only the first
  may be papered over with fresh baselines. This module decides from git alone,
  in a checkout of the branch head:

    * the **green run** is the last commit on this branch whose visual job passed;
    * the branch's *own contribution* at a commit is its diff from the merge base
      with the target branch — what the branch adds on top of main, whether main
      was merged in (`git merge origin/main`) or the branch was rebased (history
      rewritten, the green commit no longer an ancestor);
    * if that contribution is unchanged between the green commit and the head, for
      every file that is not a baseline image and not matched by `ignore_paths`,
      then nothing the branch did since the green run can explain the failure:
      it is drift. Diffs are compared with their `index` lines and hunk offsets
      stripped, as `git patch-id` does, so an unrelated change above the branch's
      hunk does not look like a branch change.

  Everything else refuses, and the failure takes the normal fix path: no green
  run on record, the green commit unreachable, the head *being* the green commit
  or having its tree (the run is a flake or an infrastructure failure, not drift),
  a head that is already an auto-refresh commit (a refresh that did not clear the
  failure is not repeated), and any file the branch changed itself since the green
  run. A file both the branch and main edited near each other reads as the
  branch's own change: the heuristic errs towards "do not refresh".
  """

  alias Arbiter.Worker.VisualBaselines.Config

  @refresh_subject "Refresh visual baselines after syncing main (auto)"

  @type verdict ::
          :ok
          | {:skip,
             :no_green_run
             | :green_unavailable
             | :head_is_green
             | :no_change_since_green
             | :already_refreshed
             | :no_merge_base
             | {:own_changes, [String.t()]}}

  @doc "The subject line of the commit `Arbiter.Worker.VisualBaselines` makes."
  @spec refresh_subject() :: String.t()
  def refresh_subject, do: @refresh_subject

  @doc """
  Judge `head` in `checkout` against the last `green` commit, with `target` the
  tip of the branch it merges into.
  """
  @spec decide(String.t(), String.t(), String.t(), String.t() | nil, Config.t()) :: verdict()
  def decide(_checkout, _target, _head, green, _config) when green in [nil, ""],
    do: {:skip, :no_green_run}

  def decide(_checkout, _target, head, green, _config) when head == green,
    do: {:skip, :head_is_green}

  def decide(checkout, target, head, green, config) do
    with :ok <- not_refreshed(checkout, head),
         :ok <- have_commit(checkout, green),
         :ok <- tree_changed(checkout, head, green),
         {:ok, then_base} <- merge_base(checkout, green, target),
         {:ok, now_base} <- merge_base(checkout, head, target) do
      own_changes(checkout, {then_base, green}, {now_base, head}, config)
    end
  end

  defp not_refreshed(checkout, head) do
    case git(checkout, ["log", "-1", "--format=%s", head]) do
      {:ok, @refresh_subject} -> {:skip, :already_refreshed}
      _ -> :ok
    end
  end

  defp have_commit(checkout, sha) do
    cond do
      commit?(checkout, sha) ->
        :ok

      match?({:ok, _}, git(checkout, ["fetch", "--no-tags", "origin", sha])) and
          commit?(checkout, sha) ->
        :ok

      true ->
        {:skip, :green_unavailable}
    end
  end

  defp commit?(checkout, sha),
    do: match?({:ok, _}, git(checkout, ["cat-file", "-e", sha <> "^{commit}"]))

  defp tree_changed(checkout, head, green) do
    with {:ok, a} <- git(checkout, ["rev-parse", head <> "^{tree}"]),
         {:ok, b} <- git(checkout, ["rev-parse", green <> "^{tree}"]) do
      if a == b, do: {:skip, :no_change_since_green}, else: :ok
    else
      _ -> {:skip, :green_unavailable}
    end
  end

  defp merge_base(checkout, a, b) do
    case git(checkout, ["merge-base", a, b]) do
      {:ok, sha} when sha != "" -> {:ok, sha}
      _ -> {:skip, :no_merge_base}
    end
  end

  defp own_changes(checkout, {then_base, green}, {now_base, head}, config) do
    with {:ok, then_files} <- changed_files(checkout, then_base, green),
         {:ok, now_files} <- changed_files(checkout, now_base, head) do
      changed =
        (then_files ++ now_files)
        |> Enum.uniq()
        |> Enum.reject(&irrelevant?(&1, config))
        |> Enum.filter(fn file ->
          signature(checkout, then_base, green, file) != signature(checkout, now_base, head, file)
        end)
        |> Enum.sort()

      if changed == [], do: :ok, else: {:skip, {:own_changes, changed}}
    else
      _ -> {:skip, :no_merge_base}
    end
  end

  defp changed_files(checkout, base, tip) do
    with {:ok, out} <- git(checkout, ["diff", "--name-only", "--no-renames", "-z", base, tip]) do
      {:ok, String.split(out, <<0>>, trim: true)}
    end
  end

  defp irrelevant?(file, config) do
    String.starts_with?(file, config.baseline_dir <> "/") or
      Enum.any?(config.ignore_paths, &glob_match?(&1, file))
  end

  # The branch's change to one file, stripped of what moves when main edits
  # elsewhere in it: blob ids and hunk line numbers.
  defp signature(checkout, base, tip, file) do
    case git(checkout, ["diff", "--binary", "--no-renames", base, tip, "--", file]) do
      {:ok, diff} ->
        diff
        |> String.split("\n")
        |> Enum.reject(&String.starts_with?(&1, "index "))
        |> Enum.map(fn
          "@@" <> _ -> "@@"
          line -> line
        end)
        |> Enum.join("\n")

      {:error, _} ->
        :unreadable
    end
  end

  @doc """
  Shell-style glob over a repo-relative path: `*` stays inside a directory, `**`
  crosses them, `?` is one non-separator character.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(pattern, path) do
    regex =
      pattern
      |> String.graphemes()
      |> to_regex([])
      |> then(&Regex.compile!("^" <> &1 <> "$"))

    Regex.match?(regex, path)
  end

  defp to_regex([], acc), do: acc |> Enum.reverse() |> Enum.join()
  defp to_regex(["*", "*", "/" | rest], acc), do: to_regex(rest, ["(?:.*/)?" | acc])
  defp to_regex(["*", "*" | rest], acc), do: to_regex(rest, [".*" | acc])
  defp to_regex(["*" | rest], acc), do: to_regex(rest, ["[^/]*" | acc])
  defp to_regex(["?" | rest], acc), do: to_regex(rest, ["[^/]" | acc])
  defp to_regex([c | rest], acc), do: to_regex(rest, [Regex.escape(c) | acc])

  @doc false
  @spec git(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(checkout, args) do
    case System.cmd("git", ["-C", checkout] ++ args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim_trailing(out, "\n")}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
