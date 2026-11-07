defmodule ArbiterCli.Cmd.Doctor.SecretsAtRestTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.Doctor.SecretsAtRest

  test "n/a when the host has no service env file" do
    assert %{status: :na} = SecretsAtRest.check(:absent)
  end

  test "ok when the boot secrets are references only" do
    env = %{
      "ARBITER_CLOAK_KEY_REF" => "aws-sm:prod/arbiter#cloak",
      "SECRET_KEY_BASE_REF" => "aws-sm:prod/arbiter#skb",
      "PATH" => "/usr/bin"
    }

    result = SecretsAtRest.check(env)
    assert result.status == :ok
    assert result.detail =~ "ARBITER_CLOAK_KEY (aws-sm)"
    assert result.detail =~ "inline: none"
  end

  test "warns when a boot secret is inline, naming the key but not the value" do
    result =
      SecretsAtRest.check(%{
        "ARBITER_CLOAK_KEY" => "c2VjcmV0LWNsb2FrLWtleS12YWx1ZQ==",
        "SECRET_KEY_BASE_REF" => "aws-sm:x"
      })

    assert result.status == :warn
    assert result.detail =~ "ARBITER_CLOAK_KEY is an inline value"
    refute inspect(result) =~ "c2VjcmV0"
    assert result.hint =~ "ARBITER_CLOAK_KEY_REF"
  end

  test "warns when an inline value is shadowed by a pointer, or a pointer is malformed" do
    shadowed = SecretsAtRest.check(%{"GITHUB_TOKEN" => "ghp_x", "GITHUB_TOKEN_REF" => "file:/x"})
    assert shadowed.status == :warn
    assert shadowed.detail =~ "GITHUB_TOKEN has an inline value"

    bad = SecretsAtRest.check(%{"SECRET_KEY_BASE_REF" => "oops"})
    assert bad.status == :warn
    assert bad.detail =~ "SECRET_KEY_BASE_REF is not"
  end

  test "an inline provider token alone does not warn" do
    result = SecretsAtRest.check(%{"ANTHROPIC_API_KEY" => "sk-ant-x"})
    assert result.status == :ok
    assert result.detail =~ "inline: ANTHROPIC_API_KEY"
  end
end
