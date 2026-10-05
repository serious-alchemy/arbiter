defmodule Arbiter.Agents.Grok.CredentialTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Grok.Credential

  setup do
    prev = Application.get_env(:arbiter, :grok_credential_env)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :grok_credential_env, prev),
        else: Application.delete_env(:arbiter, :grok_credential_env)
    end)
  end

  test "no broker configured: no credential env" do
    Application.delete_env(:arbiter, :grok_credential_env)
    assert Credential.env([]) == []
  end

  test "a static list is passed through" do
    Application.put_env(:arbiter, :grok_credential_env, [{"XAI_API_KEY", "k"}])
    assert Credential.env([]) == [{"XAI_API_KEY", "k"}]
  end

  test "a function receives the spawn opts" do
    Application.put_env(:arbiter, :grok_credential_env, fn opts ->
      [{"GROK_AUTH_PROVIDER_COMMAND", "broker " <> Keyword.fetch!(opts, :task_id)}]
    end)

    assert Credential.env(task_id: "bd-1") == [{"GROK_AUTH_PROVIDER_COMMAND", "broker bd-1"}]
  end

  test "a malformed seam value is ignored rather than crashing a spawn" do
    Application.put_env(:arbiter, :grok_credential_env, :nope)
    assert Credential.env([]) == []
  end
end
