defmodule Arbiter.Mergers.CiSkip do
  @moduledoc """
  The forge-specific halves of the merge train's CI-skipped pushes (bd-4y9dno).

  A merge train spends CI only on its head. A commit pushed for an MR that is not
  the head (a conflict resolution, a fix pass) goes up with the forge's own
  "skip CI" mechanism, so the branch is safe on the remote and reviewable without
  a pipeline; when the MR becomes the head, `trigger/3` starts the pipeline it
  needs. Both go through optional `Arbiter.Mergers.Merger` callbacks, so an
  adapter that cannot do both simply never skips.

    * `mechanism/2` — `ci_skip_mechanism/1`: `{:push_option, "ci.skip"}` on GitLab,
      `{:commit_marker, "[skip ci]"}` on GitHub (only with a dispatch workflow
      configured), `nil` otherwise.
    * `trigger/3` — `trigger_pipeline/2`: a GitLab merge request pipeline, a GitHub
      `workflow_dispatch` on the PR's head branch.

  "Pipelines must succeed" on the forge keeps a skipped head from merging; the
  Watchdog enforces the same on its side (it merges a CI-skipped head only after
  the pipeline it triggered is green).
  """

  @type mechanism :: Arbiter.Mergers.Merger.ci_skip_mechanism()

  @doc "The adapter's CI-skip mechanism for `opts`, or `nil` when it has none."
  @spec mechanism(module() | nil, map()) :: mechanism() | nil
  def mechanism(adapter, opts \\ %{})

  def mechanism(adapter, opts) when is_atom(adapter) and not is_nil(adapter) do
    if callable?(adapter, :ci_skip_mechanism, 1) and callable?(adapter, :trigger_pipeline, 2) do
      adapter.ci_skip_mechanism(opts)
    end
  end

  def mechanism(_adapter, _opts), do: nil

  @doc "Start the pipeline for the MR's current head."
  @spec trigger(module() | nil, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def trigger(adapter, mr_ref, opts \\ %{}) do
    if is_atom(adapter) and not is_nil(adapter) and callable?(adapter, :trigger_pipeline, 2),
      do: adapter.trigger_pipeline(mr_ref, opts),
      else: {:error, :unsupported}
  end

  defp callable?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
end
