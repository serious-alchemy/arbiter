defmodule Arbiter.Worker.WorkerEnvWithholdingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Projection
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv

  defp workspace(attrs) do
    {:ok, ws} =
      Ash.create(Workspace, Map.merge(%{name: "wh-#{System.unique_integer([:positive])}"}, attrs))

    ws
  end

  defp task_in(ws) do
    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    task
  end

  setup do
    ws =
      workspace(%{
        worker_env: %{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        },
        secrets: %{"prod_ro_url" => "postgres://ro", "github_worker_token" => "ghp_x"}
      })

    %{ws: ws, task: task_in(ws)}
  end

  test "no projection and no guardrail rules: every worker_env var, as before", %{task: task} do
    {pairs, _} = WorkerEnv.resolve(task.id)
    assert Enum.sort(pairs) == [{"API_TOKEN", "tok_secret"}, {"LOG_LEVEL", "debug"}]
  end

  test "an unguarded projection changes nothing", %{task: task} do
    {pairs, _} = WorkerEnv.resolve(task.id, projection: Projection.unguarded())
    assert {"API_TOKEN", "tok_secret"} in pairs
  end

  test "a sealed projection withholds secret-flagged vars and keeps plain ones", %{task: task} do
    {pairs, secrets} = WorkerEnv.resolve(task.id, projection: Projection.sealed())
    assert pairs == [{"LOG_LEVEL", "debug"}]
    # still redacted from output: withheld is not the same as unredacted
    assert "tok_secret" in secrets
  end

  test "a projection adds the named secrets under the binding's env var names", %{task: task} do
    projection = %{Projection.sealed() | env: [{"RO_DATABASE_URL", "prod_ro_url"}]}
    {pairs, secrets} = WorkerEnv.resolve(task.id, projection: projection)

    assert {"RO_DATABASE_URL", "postgres://ro"} in pairs
    refute Enum.any?(pairs, fn {_, v} -> v == "ghp_x" end)
    assert "postgres://ro" in secrets
  end

  test "a projected secret may live in worker_env instead", %{task: task} do
    projection = %{Projection.sealed() | env: [{"TOK", "API_TOKEN"}]}
    {pairs, _} = WorkerEnv.resolve(task.id, projection: projection)
    assert {"TOK", "tok_secret"} in pairs
  end

  test "a projected secret that does not exist is skipped, not a crash", %{task: task} do
    projection = %{Projection.sealed() | env: [{"X", "no_such_secret"}]}
    {pairs, _} = WorkerEnv.resolve(task.id, projection: projection)
    refute Enum.any?(pairs, fn {k, _} -> k == "X" end)
  end

  describe "guardrail rules are configured but the caller passed no projection" do
    setup do
      Application.put_env(:arbiter, :guardrail_subject_rules, [
        %{match: %{provider: "claude"}, tier: :probation}
      ])

      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)
    end

    test "fails closed: secret-flagged vars are withheld", %{task: task} do
      {pairs, _} = WorkerEnv.resolve(task.id)
      assert pairs == [{"LOG_LEVEL", "debug"}]
    end

    test "an explicit unguarded projection still means legacy", %{task: task} do
      {pairs, _} = WorkerEnv.resolve(task.id, projection: Projection.unguarded())
      assert {"API_TOKEN", "tok_secret"} in pairs
    end
  end
end
