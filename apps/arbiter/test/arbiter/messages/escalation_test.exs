defmodule Arbiter.Messages.EscalationTest do
  @moduledoc """
  bd-8if9zt (ticket lifecycle 6/13, AC1–AC2): every escalation carries a typed
  kind, and a ticket-scoped kind is deduplicated by `(kind, ticket)` — not by
  its subject text.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Escalation
  alias Arbiter.Messages.EscalationKind
  alias Arbiter.Messages.Message

  require Ash.Query

  @ws "ws-escalation-test"

  defp ticket, do: "bd-esc-#{System.unique_integer([:positive])}"

  defp post(kind, task_ref, subject, extra \\ %{}) do
    Escalation.post(
      Map.merge(
        %{
          kind: kind,
          workspace_id: @ws,
          task_ref: task_ref,
          from_ref: task_ref,
          subject: subject,
          body: "body: " <> subject
        },
        extra
      )
    )
  end

  defp open_for(task_ref) do
    Message
    |> Ash.Query.filter(task_ref == ^task_ref and kind == :escalation and is_nil(cleared_at))
    |> Ash.read!()
  end

  describe "the kind" do
    test "an escalation without a kind is refused" do
      assert {:error, %Ash.Error.Invalid{}} =
               Message.send_mail(%{
                 kind: :escalation,
                 to_ref: "coordinator",
                 workspace_id: @ws,
                 subject: "untyped",
                 body: "x"
               })
    end

    test "an unknown kind is refused" do
      assert {:error, %Ash.Error.Invalid{}} =
               Message.send_mail(%{
                 kind: :escalation,
                 escalation_kind: :not_a_kind,
                 to_ref: "coordinator",
                 workspace_id: @ws,
                 body: "x"
               })
    end

    test "a message that is not an escalation carries no escalation kind" do
      assert {:error, %Ash.Error.Invalid{}} =
               Message.send_mail(%{
                 kind: :info,
                 escalation_kind: :merge_blocked,
                 to_ref: "coordinator",
                 workspace_id: @ws,
                 body: "x"
               })
    end

    test "post/1 addresses the coordinator and stamps the kind" do
      task = ticket()
      assert {:ok, m} = post(:merge_blocked, task, "merge blocked")

      assert m.kind == :escalation
      assert m.escalation_kind == :merge_blocked
      assert m.to_ref == Message.coordinator_ref()
      assert m.task_ref == task
    end

    test "post/1 refuses a kind outside the enum" do
      assert {:error, {:unknown_escalation_kind, :bogus}} = post(:bogus, ticket(), "x")
    end
  end

  describe "(kind, ticket) dedupe" do
    test "the same kind twice for one ticket, with different subjects, is one open item" do
      task = ticket()

      {:ok, first} = post(:merge_blocked, task, "#{task} merge blocked — conflict")
      {:ok, second} = post(:merge_blocked, task, "#{task} merge blocked — CI failed")

      assert second.id == first.id
      assert [open] = open_for(task)
      assert open.subject == "#{task} merge blocked — CI failed"
      assert open.body == "body: #{task} merge blocked — CI failed"
    end

    test "a different kind for the same ticket is its own item" do
      task = ticket()

      {:ok, _} = post(:merge_blocked, task, "blocked")
      {:ok, _} = post(:tracker_sync_failed, task, "sync failed")

      assert length(open_for(task)) == 2
    end

    test "the same kind for another ticket is its own item" do
      {:ok, a} = post(:merge_blocked, ticket(), "blocked")
      {:ok, b} = post(:merge_blocked, ticket(), "blocked")

      refute a.id == b.id
    end

    test "once the open item is cleared, the next raise is a fresh item" do
      task = ticket()
      {:ok, first} = post(:worker_stopped, task, "stopped")
      {:ok, _} = Message.mark_cleared(first.id)

      {:ok, second} = post(:worker_stopped, task, "stopped again")

      refute second.id == first.id
      assert [%{id: id}] = open_for(task)
      assert id == second.id
    end

    test "an agent-raised escalation is never folded into another" do
      task = ticket()
      {:ok, a} = post(:agent_raised, task, "question one")
      {:ok, b} = post(:agent_raised, task, "question two")

      refute a.id == b.id
      assert length(open_for(task)) == 2
    end

    test "a system kind is not deduplicated by post/1" do
      {:ok, a} = post(:quota_poll_failing, "system", "quota poll failing")
      {:ok, b} = post(:quota_poll_failing, "system", "quota poll failing")

      refute a.id == b.id
    end
  end

  describe "the enum" do
    test "ticket and system kinds are disjoint and together are every kind" do
      ticket = MapSet.new(EscalationKind.ticket_kinds())
      system = MapSet.new(EscalationKind.system_kinds())

      assert MapSet.disjoint?(ticket, system)

      assert Enum.sort(EscalationKind.all()) ==
               Enum.sort(MapSet.to_list(MapSet.union(ticket, system)))
    end

    test "every cause a kind records is an attention cause the ticket accepts" do
      for kind <- EscalationKind.ticket_kinds(), cause = EscalationKind.cause(kind) do
        assert cause in Arbiter.Tasks.Issue.attention_causes(), "#{kind} → #{cause}"
      end
    end
  end

  describe "no untyped escalation writes (AC1)" do
    # Every `kind: :escalation` literal in the app's source must sit in a map
    # that also names its `escalation_kind:`, or go through `Escalation.post/1`,
    # which requires one. A new write site that forgets the kind fails here,
    # before the resource's validation would refuse it at runtime.
    test "every kind: :escalation literal in apps/arbiter/lib names an escalation_kind" do
      lib = Path.expand("../../../lib", __DIR__)

      offenders =
        for path <- Path.wildcard(Path.join(lib, "**/*.ex")),
            {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            String.match?(line, ~r/^\s*kind: :escalation,?\s*$/),
            not typed_nearby?(path, n),
            do: "#{Path.relative_to(path, lib)}:#{n}"

      assert offenders == []
    end

    defp typed_nearby?(path, n) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.slice(max(n - 3, 0), 6)
      |> Enum.any?(&String.contains?(&1, "escalation_kind:"))
    end
  end
end
