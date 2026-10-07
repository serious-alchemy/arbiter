defmodule Arbiter.MCP.AccountSetToolTest do
  @moduledoc "bd-1kr3qf: the `account_set` MCP tool, and what stays off MCP."
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.{Fields, ProviderAccount}
  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Parity.Manifest

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}
  @worker %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}

  defp account!(slug, attrs \\ %{}),
    do: Ash.create!(ProviderAccount, Map.merge(%{provider: :claude, slug: slug}, attrs))

  defp tool, do: Enum.find(Catalog.all(), &(&1.name == "account_set"))

  test "is a coordinator-only catalog entry" do
    assert :coordinator in tool().tiers
    refute :worker in tool().tiers
    assert Enum.any?(Catalog.visible(@coordinator), &(&1.name == "account_set"))
    refute Enum.any?(Catalog.visible(@worker), &(&1.name == "account_set"))
  end

  test "its schema offers exactly the non-secret registry fields, plus the ref" do
    props = tool().input_schema["properties"]
    assert Enum.sort(Map.keys(props)) == Enum.sort(["ref" | Fields.names(:mcp)])
    assert tool().input_schema["required"] == ["ref"]
    assert tool().input_schema["additionalProperties"] == false

    assert Enum.sort(Map.keys(props["quota_config"]["properties"])) ==
             Enum.sort(Fields.quota_keys())
  end

  test "edits fields and a quota_config patch, and clears with null" do
    account!("mcp-edit", %{quota_config: %{"weekly_threshold" => 0.8, "paced_floor" => 0.3}})

    assert {:ok, %{account: shown}} =
             Catalog.call(@coordinator, "account_set", %{
               "ref" => "claude:mcp-edit",
               "label" => "Via MCP",
               "enabled" => false,
               "max_concurrent" => 2,
               "quota_config" => %{"weekly_threshold" => nil, "throttle_threshold" => 0.6}
             })

    assert shown.label == "Via MCP"
    assert shown.enabled == false
    assert shown.max_concurrent == 2
    assert shown.quota_config == %{"paced_floor" => 0.3, "throttle_threshold" => 0.6}
    refute Map.has_key?(shown, :credentials)

    assert {:ok, %{label: "Via MCP", max_concurrent: 2}} = Accounts.get_account("mcp-edit")
  end

  test "a bad value is an invalid error and writes nothing" do
    account!("mcp-bad", %{label: "Before"})

    assert {:tool_error, message, "validation_error"} =
             Catalog.call(@coordinator, "account_set", %{
               "ref" => "mcp-bad",
               "label" => "After",
               "quota_config" => %{"threshold_mode" => "bogus"}
             })

    assert message =~ "threshold_mode"
    assert {:ok, %{label: "Before"}} = Accounts.get_account("mcp-bad")
  end

  test "ref is required, an unknown ref is not_found, and an empty edit is refused" do
    account!("mcp-empty")

    assert {:tool_error, _, "validation_error"} =
             Catalog.call(@coordinator, "account_set", %{"label" => "x"})

    assert {:tool_error, _, "not_found"} =
             Catalog.call(@coordinator, "account_set", %{"ref" => "nope", "label" => "x"})

    assert {:tool_error, _, "validation_error"} =
             Catalog.call(@coordinator, "account_set", %{"ref" => "mcp-empty"})
  end

  test "identity, credential and secret fields are rejected, not ignored" do
    account!("mcp-secret")

    for extra <- [%{"slug" => "x"}, %{"secret" => "s3cret"}, %{"credential" => "c"}] do
      assert {:tool_error, _, "validation_error"} =
               Catalog.call(
                 @coordinator,
                 "account_set",
                 Map.merge(%{"ref" => "mcp-secret", "label" => "x"}, extra)
               )
    end

    assert {:ok, %{label: nil}} = Accounts.get_account("mcp-secret")
  end

  describe "what stays off MCP (AC 3)" do
    test "no tool creates, attaches, rotates, logs in or stores a secret" do
      names = Enum.map(Catalog.all(), & &1.name)

      for forbidden <- ~w(account_rotate account_login account_credential account_secret
                          account_create account_attach account_detach account_merge
                          account_delete) do
        refute forbidden in names
      end
    end

    test "the manifest rules rotate, login and detach :intentional on MCP" do
      %{operations: ops} = Manifest.load!()

      for id <- ~w(accounts/rotate_credential_store_secret accounts/start_provider_login_relay
                   accounts/detach_workspace_from_account) do
        op = Enum.find(ops, &(&1.id == id))
        assert op.mcp == nil
        assert {:intentional, _} = op.absent.mcp
      end

      update = Enum.find(ops, &(&1.id == "accounts/update_account_label_plan_enabled_max"))
      assert update.mcp == ["account_set"]
      assert update.status == :full
    end
  end
end
