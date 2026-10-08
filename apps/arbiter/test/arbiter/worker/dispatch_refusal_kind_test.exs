defmodule Arbiter.Worker.DispatchRefusalKindTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Dispatch

  @table [
    {{:task_not_found, "t"}, :not_found},
    {{:task_closed, "t"}, :conflict},
    {{:not_dispatchable, "t", {:column, :backlog}}, :conflict},
    {{:task_awaiting_review, "t"}, :conflict},
    {{:agent_session_active, "t"}, :conflict},
    {{:worker_active, :running}, :conflict},
    {:no_outpost, :conflict},
    {:no_session, :conflict},
    {{:account_at_capacity, %{}}, :conflict},
    {{:no_node_capacity, %{}}, :conflict},
    {{:provider_constraint, :claude, "p"}, :conflict},
    {{:sandbox_backend, :gemini, "p"}, :conflict},
    {{:capability_missing, :claude, "p"}, :conflict},
    {{:below_floor, :claude, "p"}, :conflict},
    {{:slot_cap_full, %{}}, :conflict},
    {:no_repo_configured, :invalid},
    {{:repo_not_found, "r"}, :invalid},
    {{:ambiguous_repo, ["a", "b"]}, :invalid},
    {:repo_unknown, :invalid},
    {{:pending_migrations, 2}, :busy},
    {{:migrations_check_failed, :unreachable}, :busy},
    {:something_else, :internal},
    {{:something_else, 1}, :internal}
  ]

  for {reason, kind} <- @table do
    test "#{inspect(reason)} is #{kind}" do
      assert Dispatch.refusal_kind(unquote(Macro.escape(reason))) == unquote(kind)
    end
  end
end
