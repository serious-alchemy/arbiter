defmodule Arbiter.Worker.MergeProbe do
  @moduledoc """
  The conflict probe of the merge train's waiting MRs (bd-4y9dno, phase 2 of
  bd-1754qj).

  An MR that waits behind the target's merge head used to find out it conflicts
  only when its turn came: the head merged, the target moved, and the conflict
  surfaced at the front of the line, where resolving and re-reviewing it holds
  the whole train. Probing each waiting MR whenever the target moves finds the
  conflict while it waits.

  `check/1` is `git merge-tree --write-tree` of the MR's branch against the
  target's tip, both fetched into the repo's own object store (`origin` tips
  only). It writes merge objects and nothing else: no commit, no ref, no index,
  no worktree and no push. A clean merge means nothing to do. Anything git cannot
  answer (no repo, a fetch that fails, a branch the forge no longer has) is
  `:unknown`, which callers treat as "no conflict seen": the probe only ever
  brings a conflict forward, it never blocks a merge.

  The answer carries the target tip and branch tip it judged. A caller that
  passes them back as `:since` is told `:unchanged` (after the fetch, before any
  merge) when neither moved, so a waiting MR costs one `merge-tree` per move of
  the target, not one per poll.
  """

  alias Arbiter.Worker.Worktree

  @type args :: %{
          required(:repo_path) => String.t() | nil,
          required(:branch) => String.t(),
          required(:target) => String.t(),
          optional(:since) => %{head: String.t(), target_tip: String.t()} | nil,
          optional(atom()) => term()
        }

  @type verdict :: :clean | :unknown | :unchanged | {:conflict, [String.t()]}
  @type answer :: %{verdict: verdict(), target_tip: String.t() | nil, head: String.t() | nil}

  @doc "Probe `branch` against `target` in `repo_path`. See the moduledoc."
  @spec check(args()) :: answer()
  def check(%{repo_path: repo, branch: branch, target: target} = args)
      when is_binary(repo) and is_binary(branch) and branch != "" and is_binary(target) and
             target != "" do
    with true <- File.dir?(repo),
         {:ok, tips} <- Worktree.fetch_origin_tips(repo, Enum.uniq([branch, target])) do
      tip = Map.fetch!(tips, target)
      head = Map.fetch!(tips, branch)

      verdict =
        case Map.get(args, :since) do
          %{head: ^head, target_tip: ^tip} -> :unchanged
          _ -> merge_verdict(repo, tip, head)
        end

      %{verdict: verdict, target_tip: tip, head: head}
    else
      _ -> unknown()
    end
  rescue
    _ -> unknown()
  end

  def check(_args), do: unknown()

  defp merge_verdict(repo, tip, head) do
    case Worktree.merge_conflict(repo, tip, head) do
      :clean -> :clean
      {:conflict, files} -> {:conflict, files}
      :unknown -> :unknown
    end
  end

  defp unknown, do: %{verdict: :unknown, target_tip: nil, head: nil}
end
