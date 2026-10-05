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

  describe "broker fallback (bd-9p4lx9)" do
    setup do
      Application.delete_env(:arbiter, :grok_credential_env)
      dir = Path.join(System.tmp_dir!(), "grok-cred-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      arb = Path.join(dir, "arb")
      File.write!(arb, "#!/bin/sh\n")
      File.chmod!(arb, 0o755)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, arb: arb}
    end

    test "with no override and a grok_home, the broker's wrapper env is used", ctx do
      home = Path.join(ctx.dir, "home/.grok")
      env = Credential.env(grok_home: home, arb_path: ctx.arb)

      assert {"GROK_AUTH_PROVIDER_COMMAND", script} =
               List.keyfind(env, "GROK_AUTH_PROVIDER_COMMAND", 0)

      assert File.regular?(script)
      assert {"XAI_API_KEY", false} in env
    end

    test "an explicit override wins over the broker", ctx do
      Application.put_env(:arbiter, :grok_credential_env, [{"XAI_API_KEY", "k"}])

      assert Credential.env(grok_home: Path.join(ctx.dir, ".grok"), arb_path: ctx.arb) ==
               [{"XAI_API_KEY", "k"}]
    end

    test "an unusable broker (no arb) is not signed in rather than a crash", ctx do
      assert Credential.env(
               grok_home: Path.join(ctx.dir, ".grok"),
               arb_path: Path.join(ctx.dir, "nope")
             ) == []
    end
  end
end
