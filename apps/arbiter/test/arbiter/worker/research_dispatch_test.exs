defmodule Arbiter.Worker.ResearchDispatchTest do
  @moduledoc """
  bd-6ircwr end to end: dispatching a `research_read` ticket hands the spawned
  agent a token carrying the claim (and records the grant), while a workspace that
  never bound the permission gets neither. The stubbed `claude` writes the
  `ARB_TOKEN` it was spawned with.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Permissions, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker.Dispatch

  @repo "rd/repo"

  setup do
    claude_credential_env!()
    out = Path.join(System.tmp_dir!(), "research-token-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(out) end)

    sandbox =
      TestSandbox.provision!("research-dispatch", stub: ~s(printf %s "$ARB_TOKEN" > #{out}))

    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})
    on_exit(fn -> TestSandbox.own_live_workers!(sandbox) end)
    %{out: out}
  end

  defp workspace!(config) do
    n = System.unique_integer([:positive])
    Ash.create!(Workspace, %{name: "rd-#{n}", prefix: "rd#{n}", config: config})
  end

  defp research_task!(ws) do
    Ash.create!(
      Issue,
      %{
        title: "research arbiter",
        workspace_id: ws.id,
        issue_type: :research,
        permissions: ["research_read"]
      },
      context: %{guardrail_authority: :coordinator, permission_actor: "t"}
    )
  end

  defp token_scope(out) do
    token = await_file(out, 200)
    {:ok, scope} = Arbiter.MCP.Scope.from_token(token)
    scope
  end

  defp await_file(file, tries) do
    case File.read(file) do
      {:ok, body} when body != "" ->
        body

      _ when tries > 0 ->
        receive do
        after
          50 -> await_file(file, tries - 1)
        end

      _ ->
        flunk("the stubbed agent never wrote #{file}")
    end
  end

  defp dispatch(task) do
    Dispatch.dispatch(task.id, force: true, repo: @repo, start_claude: true)
  end

  defp granted(task), do: task |> Permissions.events() |> Enum.filter(&(&1.event == :granted))

  test "a bound workspace's research run is handed the claim, and the grant is audited", %{
    out: out
  } do
    ws = workspace!(%{"guardrails" => %{"bindings" => %{"research_read" => %{}}}})
    task = research_task!(ws)

    {:ok, _} = dispatch(task)

    assert Arbiter.MCP.Scope.permission?(token_scope(out), "research_read")
    assert [%{permission: "research_read", source: :system}] = granted(task)
  end

  test "off by default: a workspace that binds nothing gets no claim and no grant", %{out: out} do
    task = research_task!(workspace!(%{}))

    {:ok, _} = dispatch(task)

    refute Arbiter.MCP.Scope.permission?(token_scope(out), "research_read")
    assert granted(task) == []
  end
end
