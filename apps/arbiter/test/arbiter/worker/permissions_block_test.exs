defmodule Arbiter.Worker.PermissionsBlockTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Projection
  alias Arbiter.Worker.PermissionsBlock

  test "an unguarded spawn gets no block: the prompt is exactly what it was" do
    assert PermissionsBlock.render(Projection.unguarded()) == ""
    assert PermissionsBlock.render(nil) == ""
  end

  test "a guarded spawn with nothing granted says so and what a 403 means" do
    block = PermissionsBlock.render(Projection.sealed())
    assert block =~ "PERMISSIONS"
    assert block =~ "none"
    assert block =~ "403"
    assert block =~ "not granted"
  end

  test "lists what was granted, by name, without any secret value or secret name" do
    projection = %{
      Projection.sealed()
      | granted: ["network:api.example.com:443", "prod_read"],
        hosts: ["api.example.com:443"],
        env: [{"RO_DATABASE_URL", "prod_ro_url"}],
        tunnels: [{5432, "replica.internal", 5432}]
    }

    block = PermissionsBlock.render(projection)
    assert block =~ "network:api.example.com:443"
    assert block =~ "prod_read"
    assert block =~ "RO_DATABASE_URL"
    assert block =~ "127.0.0.1:5432"
    refute block =~ "prod_ro_url"
  end

  test "names the ssh agent without a key path" do
    projection = %{
      Projection.sealed()
      | granted: ["prod_ssh"],
        ssh: %{key_secret: "prod_ssh_key", hosts: ["prod.internal:22"]}
    }

    block = PermissionsBlock.render(projection)
    assert block =~ "SSH_AUTH_SOCK"
    assert block =~ "prod.internal:22"
    refute block =~ "prod_ssh_key"
  end

  test "lists what was withheld and why" do
    projection = %{
      Projection.sealed()
      | withheld: [%{permission: "prod_ssh", reason: "tier probation is below privileged"}]
    }

    block = PermissionsBlock.render(projection)
    assert block =~ "prod_ssh"
    assert block =~ "below privileged"
  end

  test "tells the worker never to work around a withheld permission and how to ask" do
    block = PermissionsBlock.render(Projection.sealed())
    assert block =~ "permission_request"
    assert block =~ "recorded, not granted"
    assert block =~ "unmet"
  end

  test "a reviewer's block says reviewers hold no action permissions" do
    block = PermissionsBlock.render(Projection.sealed(role: :reviewer))
    assert block =~ "reviewer"
  end
end
