defmodule Arbiter.Tasks.IssueFieldsTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueFields

  @internal ~w(circuit_breaker_tripped circuit_breaker_reason circuit_breaker_sha review_count
               review_cap_escalated last_verdict last_verdict_sha last_reviewed_sha
               last_reviewed_at last_seen_comment_id posted_findings settled_threads
               review_only review_automation pr_opened_notified_ref pr_opened_transitioned_ref
               skills change_origin)

  defp accepted(action),
    do:
      action
      |> then(&Ash.Resource.Info.action(Issue, &1))
      |> Map.fetch!(:accept)
      |> Enum.map(&to_string/1)

  describe "allow-list" do
    test "every allowed field is something the action actually takes" do
      governed = fn action ->
        a = Ash.Resource.Info.action(Issue, action)
        Enum.map(a.accept ++ Enum.map(a.arguments, & &1.name), &to_string/1)
      end

      assert IssueFields.create_fields() -- governed.(:create) == []
      assert IssueFields.update_fields() -- governed.(:update) == []
    end

    test "no internal review / breaker / audit field is allowed on either action" do
      for field <- @internal do
        refute field in IssueFields.create_fields(), "#{field} must not be create-writable"
        refute field in IssueFields.update_fields(), "#{field} must not be update-writable"
      end
    end

    test "everything the action accepts but the list omits is denied (allow-list, not deny-list)" do
      for action <- [:create, :update],
          field <- accepted(action) -- IssueFields.allowed(action) do
        assert IssueFields.denied(%{field => "x"}, action) == [field]
      end
    end

    test "change_origin is denied on both, unknown keys are left to Ash" do
      assert IssueFields.denied(%{"change_origin" => "x"}, :update) == ["change_origin"]
      assert IssueFields.denied(%{"change_origin" => "x"}, :create) == ["change_origin"]
      assert IssueFields.denied(%{"nope" => 1, "title" => "t"}, :update) == []
    end

    test "check/2 names every offending key" do
      assert {:error, {:invalid, msg}} =
               IssueFields.check(
                 %{"last_verdict" => "x", "skills" => %{}, "title" => "t"},
                 :update
               )

      assert msg =~ "last_verdict"
      assert msg =~ "skills"
      assert :ok = IssueFields.check(%{"title" => "t", "priority" => 1}, :update)
    end
  end

  describe "MCP specs stay inside the allow-list" do
    defp props(tool) do
      Catalog.all()
      |> Enum.find(&(&1.name == tool))
      |> get_in([:input_schema, "properties"])
      |> Map.keys()
    end

    # `force`, `workspace` and `id` are call options; `summary` picks the
    # response shape (P-13); `assignee` is the deprecated accept-and-ignore
    # field, never an Issue attribute.
    @options ~w(id force workspace assignee summary)

    defp outside(tool, allowed) do
      Enum.reject(props(tool), &(&1 in @options or &1 in allowed))
    end

    test "ticket_create takes no field the REST allow-list refuses" do
      assert outside("ticket_create", IssueFields.create_fields()) == []
    end

    test "ticket_update takes no field the REST allow-list refuses" do
      assert outside("ticket_update", IssueFields.update_fields()) == []
    end
  end
end
