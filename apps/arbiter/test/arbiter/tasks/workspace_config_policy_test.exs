defmodule Arbiter.Tasks.WorkspaceConfigPolicyTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace

  defmodule Rejecting do
    @behaviour Arbiter.Tasks.Workspace.ConfigPolicy
    def check(%{"forbidden" => _}, _ctx), do: {:error, "forbidden by org policy"}

    def check(%{"annotate" => _} = c, ctx),
      do: {:ok, Map.put(c, "seen_action", to_string(ctx.action))}

    def check(_c, _ctx), do: :ok
  end

  setup do
    prev = Application.get_env(:arbiter, :workspace_config_policy)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :workspace_config_policy, prev),
        else: Application.delete_env(:arbiter, :workspace_config_policy)
    end)
  end

  test "default policy allows everything" do
    assert {:ok, _} = Ash.create(Workspace, %{name: "cp-default", config: %{"forbidden" => 1}})
  end

  test "registered policy rejects and annotates" do
    Application.put_env(:arbiter, :workspace_config_policy, Rejecting)

    assert {:error, _} = Ash.create(Workspace, %{name: "cp-rej", config: %{"forbidden" => 1}})

    assert {:ok, ws} = Ash.create(Workspace, %{name: "cp-ann", config: %{"annotate" => 1}})
    assert ws.config["seen_action"] == "create"

    assert {:error, _} = Ash.update(ws, %{config: %{"forbidden" => 1}})
  end
end
