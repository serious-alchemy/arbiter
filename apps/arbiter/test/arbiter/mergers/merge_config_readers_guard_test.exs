defmodule Arbiter.Mergers.MergeConfigReadersGuardTest do
  @moduledoc """
  bd-73zv62: a `merge.repos.<repo>` override only works if nothing merge
  related reads the workspace-level `merge` block directly for a specific
  repo. A missed reader makes a repo half-use the workspace's forge. Every
  per-repo read goes through the resolver in `Arbiter.Mergers`
  (`merge_config/2`, `scope/2`, `resolve/2`, `for_task/1`, `for_repo/2`,
  `strategy/2`, `base_branch/2`) or `Arbiter.Mergers.ForgeRepos`.

  This guard pins the files that still touch the raw block or resolve an
  adapter from a whole workspace, each with the reason it is safe. A new file
  doing either fails here until it routes through the resolver or is added
  with a justification.
  """
  use ExUnit.Case, async: true

  @umbrella Path.expand("../../../../..", __DIR__)

  # Files allowed to read `config["merge"]…` directly (a `get_in` path, a
  # `%{"merge" => …}` pattern or literal).
  @raw_readers %{
    "apps/arbiter/lib/arbiter/mergers.ex" => "the resolver itself",
    "apps/arbiter/lib/arbiter/mergers/forge_repos.ex" =>
      "per-repo forge enumeration, built on the resolver",
    "apps/arbiter/lib/arbiter/mergers/github/config.ex" =>
      "adapter config reader; seeded via Mergers.prepare/prepare_with_repo on a scoped workspace",
    "apps/arbiter/lib/arbiter/mergers/gitlab/config.ex" =>
      "adapter config reader; seeded via Mergers.prepare/prepare_with_repo on a scoped workspace",
    "apps/arbiter/lib/arbiter/mergers/github.ex" => "an error message naming the key",
    "apps/arbiter/lib/arbiter/mergers/pr_title.ex" =>
      "a doc example; format/2 reads Workspace.pr_title_format/1 of the scoped workspace",
    "apps/arbiter/lib/arbiter/tasks/workspace.ex" =>
      "accessors (merger_strategy/1, auto_merge?/1, …) that read the workspace they are handed; " <>
        "per-repo callers hand them a Mergers.scope/2'd one",
    "apps/arbiter/lib/arbiter/tasks/workspace/changes/validate_config.ex" => "config validation",
    "apps/arbiter/lib/arbiter/worker/watchdog.ex" =>
      "merge tunables, read off the workspace scoped to the watched repo in init/1",
    "apps/arbiter/lib/arbiter/mcp/tools/workspace.ex" => "raw config display (overview)",
    "apps/arbiter_cli/lib/arbiter_cli/cmd/config/formatter.ex" => "raw config display",
    "apps/arbiter_cli/lib/arbiter_cli/cmd/workspace.ex" => "workspace create seeds merge.strategy",
    "apps/arbiter_web/lib/arbiter_web/live/workspace_index_live.ex" =>
      "shows / seeds the workspace-level strategy",
    "apps/arbiter_web/lib/arbiter_web/live/workspace_detail/policy_config_component.ex" =>
      "edits the workspace-level merge settings"
  }

  # Files allowed to resolve an adapter / strategy from a whole workspace
  # (`Mergers.for_workspace/1`, `Workspace.merger_strategy/1`).
  @workspace_resolvers %{
    "apps/arbiter/lib/arbiter/mergers.ex" => "the resolver itself",
    "apps/arbiter/lib/arbiter/mergers/forge_repos.ex" => "on each repo's effective merge block",
    "apps/arbiter/lib/arbiter/worker.ex" => "resolve_merger/2 scopes to the run's repo first",
    "apps/arbiter/lib/arbiter/tasks/pull_request.ex" => "watch_opts/1 scopes to the PR's repo",
    "apps/arbiter/lib/arbiter/reviews/external_review.ex" =>
      "prepare/1 and greenlight/1 scope to the PR's repo first",
    "apps/arbiter/lib/arbiter/tasks/workspace.ex" => "defines merger_strategy/1",
    "apps/arbiter/lib/arbiter/workflows/merge_queue.ex" =>
      "enqueue scopes to the task's repo; the workspace-level adapter is only a default that " <>
        "for_item/2 replaces before every item's adapter call",
    "apps/arbiter/lib/arbiter/workflows/pr_patrol_supervisor.ex" => "scoped to a patrolled slug",
    "apps/arbiter/lib/arbiter/workflows/review_patrol_supervisor.ex" =>
      "scoped to a patrolled slug",
    "apps/arbiter/lib/arbiter/workflows/merged_pr_finalizer_supervisor.ex" =>
      "scoped to a finalized slug",
    "apps/arbiter/lib/arbiter/workflows/pending_merge_sweeper.ex" =>
      "retry/3 scopes to the task's repo",
    "apps/arbiter/lib/arbiter/workflows/patrol_server.ex" =>
      "resolve_adapter/1, handed the patrol's scoped workspace",
    "apps/arbiter/lib/arbiter/workflows/merged_pr_finalizer.ex" =>
      "handed the finalizer's scoped workspace",
    "apps/arbiter_web/lib/arbiter_web/live/workspace_index_live.ex" =>
      "a private helper of the same name showing the workspace-level strategy"
  }

  # A `get_in` path (`["merge", "strategy"]` — not a `git merge --…` argv),
  # Access (`config["merge"]`), a `%{"merge" => …}` pattern / literal, or a
  # `Map.get(config, "merge")`.
  @raw_reader ~r/\["merge",\s*"[^-]|\["merge"\]|"merge"\s*=>|Map\.(get|fetch)\([^,]+,\s*"merge"/
  @workspace_resolver ~r/Mergers\.for_workspace\(|merger_strategy\(/

  defp lib_files do
    Path.wildcard(Path.join(@umbrella, "apps/*/lib/**/*.ex"))
  end

  # Code lines only: comment lines and lines carrying a backtick (docs and
  # comments quoting a config path) are not readers.
  defp code_matches?(path, regex) do
    path
    |> File.stream!()
    |> Enum.any?(fn line ->
      trimmed = String.trim_leading(line)

      not String.starts_with?(trimmed, "#") and not String.contains?(line, "`") and
        Regex.match?(regex, line)
    end)
  end

  defp offenders(regex, allowed) do
    lib_files()
    |> Enum.filter(&code_matches?(&1, regex))
    |> Enum.map(&Path.relative_to(&1, @umbrella))
    |> Enum.reject(&Map.has_key?(allowed, &1))
    |> Enum.sort()
  end

  test "the umbrella lib tree is where the guard looks" do
    assert File.exists?(Path.join(@umbrella, "apps/arbiter/lib/arbiter/mergers.ex"))
  end

  test "no unlisted file reads the raw merge config block" do
    assert offenders(@raw_reader, @raw_readers) == [],
           "route per-repo merge reads through Arbiter.Mergers.merge_config/2 / scope/2 " <>
             "(bd-73zv62), or add the file to @raw_readers with the reason it is safe"
  end

  test "no unlisted file resolves an adapter from a whole workspace" do
    assert offenders(@workspace_resolver, @workspace_resolvers) == [],
           "resolve per repo with Arbiter.Mergers.resolve/2 / for_repo/2 / for_task/1 " <>
             "(bd-73zv62), or add the file to @workspace_resolvers with the reason it is safe"
  end

  test "every allowlisted file still exists and still matches (no stale entries)" do
    for {allowed, regex} <- [{@raw_readers, @raw_reader}, {@workspace_resolvers, @workspace_resolver}],
        file <- Map.keys(allowed) do
      path = Path.join(@umbrella, file)
      assert File.exists?(path), "#{file} is allowlisted but gone"
      assert code_matches?(path, regex), "#{file} is allowlisted but no longer matches"
    end
  end
end
