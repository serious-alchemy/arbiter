defmodule Arbiter.Worker.GitLayoutTest do
  @moduledoc "bd-4wy1w1 (P5): which git layout a worker checkout gets."
  use ExUnit.Case, async: true

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitLayout

  defp ws(security), do: %Workspace{config: %{"agent" => %{"security" => security}}}

  test "a container backend gets a private clone; bwrap and the default keep a linked worktree" do
    assert GitLayout.for_policy(
             SecurityPolicy.resolve(ws(%{"sandbox" => %{"backend" => "podman"}}))
           ) ==
             :private_clone

    assert GitLayout.for_policy(
             SecurityPolicy.resolve(ws(%{"sandbox" => %{"backend" => "bwrap"}}))
           ) ==
             :linked_worktree

    assert GitLayout.for_policy(SecurityPolicy.resolve(nil)) == :linked_worktree
  end

  test "for_workspace/3 resolves the policy the spawn will use: repo scope and dispatch override" do
    repo_scoped = ws(%{"repos" => %{"tonic" => %{"sandbox" => %{"backend" => "podman"}}}})

    assert GitLayout.for_workspace(repo_scoped, "tonic") == :private_clone
    assert GitLayout.for_workspace(repo_scoped, "other") == :linked_worktree

    assert GitLayout.for_workspace(ws(%{}), nil, %{"sandbox" => %{"backend" => "podman"}}) ==
             :private_clone
  end
end
