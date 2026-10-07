defmodule Arbiter.Workflows.MergeQueue.FixPassDispatcherAgentOptsTest do
  @moduledoc """
  bd-cfktou: an agy pass's egress run is owned by the pass's worker and keyed
  by its task. The conflict/fix-pass spawn paths must hand both to the adapter.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  test "agent_opts/4 carries the worker as :owner and the ticket as :task_id" do
    worker = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    context = %{workspace: nil, task: %{id: "bd-pass1"}}

    opts =
      FixPassDispatcher.agent_opts([owner: worker, worktree_path: "/w"], context, "/w",
        arb_token: "t"
      )

    assert Keyword.fetch!(opts, :owner) == worker
    assert Keyword.fetch!(opts, :task_id) == "bd-pass1"
    assert Keyword.fetch!(opts, :worktree_path) == "/w"
    assert Keyword.fetch!(opts, :arb_token) == "t"
  end

  # bd-7ays3v: a pass on a podman repo runs in the container, so its adapter
  # opts carry the policy and the promise to wrap; any other pass is untouched.
  describe "under the container backend (bd-7ays3v)" do
    alias Arbiter.Agents.Claude
    alias Arbiter.Agents.SecurityPolicy
    alias Arbiter.Tasks.Workspace
    alias Arbiter.Worker.ContainerSpawn

    defp ws(backend),
      do: %Workspace{
        config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => backend}}}}
      }

    defp context(workspace),
      do: %{workspace: workspace, repo: "trib/repo", task: %{id: "bd-pass2"}}

    test "a Claude pass on a podman workspace gets the policy and sandbox_wrap" do
      workspace = ws("podman")
      policy = ContainerSpawn.pass_policy(workspace, "trib/repo", :claude)
      assert SecurityPolicy.sandbox_backend(policy) == :podman

      opts =
        FixPassDispatcher.agent_opts(
          [owner: self(), security: policy],
          context(workspace),
          "/w",
          []
        )

      assert Keyword.fetch!(opts, :security) == policy
      assert Keyword.fetch!(opts, :sandbox_wrap) == true

      # What the adapter then builds names the CLI inside the container.
      assert {:ok, argv} = Claude.default_argv("fix it", opts)
      assert "/opt/arbiter/cli/claude" in argv
    end

    test "the same pass without the wrap promise is still refused, never unjailed" do
      policy = ContainerSpawn.pass_policy(ws("podman"), "trib/repo", :claude)

      assert {:error, {:sandbox_backend_unavailable, :podman, _}} =
               Claude.default_argv("fix it", security: policy)
    end

    test "a bwrap or default workspace, or another provider, spawns exactly as before" do
      assert ContainerSpawn.pass_policy(ws("bwrap"), "trib/repo", :claude) == nil
      assert ContainerSpawn.pass_policy(nil, "trib/repo", :claude) == nil
      assert ContainerSpawn.pass_policy(ws("podman"), "trib/repo", :agy) == nil
      assert ContainerSpawn.pass_policy(ws("podman"), "trib/repo", :codex) == nil

      opts = FixPassDispatcher.agent_opts([owner: self()], context(ws("bwrap")), "/w", [])
      refute Keyword.has_key?(opts, :security)
      refute Keyword.has_key?(opts, :sandbox_wrap)
      assert ContainerSpawn.session_opts(nil, ws("bwrap"), repo: "x") == []
    end
  end
end
