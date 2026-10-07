defmodule Arbiter.Reviews.GuardTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Reviews.Guard
  alias Arbiter.Tasks.{Issue, Workspace}

  defp uniq, do: Integer.to_string(:erlang.unique_integer([:positive]))

  defp task_in(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "guard-ws-" <> uniq(), prefix: "gw" <> uniq(), config: config})

    {:ok, task} = Ash.create(Issue, %{title: "guarded", workspace_id: ws.id})
    task
  end

  describe "check/3 reads the TASK's workspace config" do
    test "refuses when the task's workspace default is off" do
      task = task_in(%{"review_automation" => %{"default" => "off"}})

      assert {:error, {:invalid, msg}} = Guard.check(task, %{}, false)
      assert msg =~ "review_automation.default"
      assert msg =~ "force"
    end

    test "refuses a repo_overrides off entry" do
      task =
        task_in(%{
          "review_automation" => %{"default" => "auto", "repo_overrides" => %{"quiet" => "off"}}
        })

      assert {:error, {:invalid, msg}} = Guard.check(task, %{"repo" => "quiet"}, false)
      assert msg =~ "repo_overrides"
    end

    test "an explicit automation: off refuses regardless of policy" do
      task = task_in(%{})
      assert {:error, {:invalid, msg}} = Guard.check(task, %{"automation" => "off"}, false)
      assert msg =~ "automation argument"
    end

    test "force overrides the refusal and keeps the resolved mode" do
      task = task_in(%{"review_automation" => %{"default" => "off"}})

      assert {:ok, %{mode: :off, source: :default}} = Guard.check(task, %{}, true)
    end

    test "auto_authors resolves :auto from the task's workspace" do
      task = task_in(%{"review_automation" => %{"default" => "flag", "auto_authors" => ["dev"]}})

      assert {:ok, %{mode: :auto, persist?: true}} =
               Guard.check(task, %{"pr_author" => "dev"}, false)
    end
  end

  describe "persist? — never write a mode nobody configured" do
    test "no review_automation config at all: resolves :flag but does not persist" do
      task = task_in(%{})

      assert {:ok, %{mode: :flag, source: :default, persist?: false}} =
               Guard.check(task, %{}, false)
    end

    test "a task with no workspace resolves :flag and does not persist" do
      assert {:ok, %{mode: :flag, persist?: false}} =
               Guard.check(%Issue{workspace_id: nil}, %{}, false)
    end

    test "an explicit automation arg persists" do
      task = task_in(%{})

      assert {:ok, %{mode: :report_only, persist?: true}} =
               Guard.check(task, %{"automation" => "propose"}, false)
    end
  end

  describe "prepare/3" do
    test "persists the mode and tracker context; a refusal touches nothing" do
      off = task_in(%{"review_automation" => %{"default" => "off"}})

      assert {:error, {:invalid, _}} =
               Guard.prepare(off, %{"tracker_context_ref" => "AX-1"}, false)

      {:ok, reloaded} = Ash.get(Issue, off.id)
      assert reloaded.review_automation == nil
      assert reloaded.tracker_context_ref == nil

      ok = task_in(%{"review_automation" => %{"default" => "report_only"}})

      assert {:ok, updated} =
               Guard.prepare(
                 ok,
                 %{"tracker_context_ref" => "AX-2", "tracker_context_type" => "jira"},
                 false
               )

      assert updated.review_automation == :report_only
      assert updated.tracker_context_ref == "AX-2"
      assert updated.tracker_context_type == :jira
    end

    test "leaves review_automation unset when no config exists" do
      task = task_in(%{})
      assert {:ok, updated} = Guard.prepare(task, %{}, false)
      assert updated.review_automation == nil
    end
  end
end
