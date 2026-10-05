defmodule Arbiter.Grok.AuthProviderTest do
  # bd-9p4lx9: what a grok worker's spawn env carries for its credential.
  use ExUnit.Case, async: true

  alias Arbiter.Grok.AuthProvider

  setup do
    dir = Path.join(System.tmp_dir!(), "gap-#{System.unique_integer([:positive])}")
    grok_home = Path.join(dir, "home/.grok")
    File.mkdir_p!(grok_home)

    arb = Path.join(dir, "fake arb")
    File.write!(arb, "#!/bin/sh\necho \"arb-called $@ expired=$GROK_AUTH_EXPIRED\"\n")
    File.chmod!(arb, 0o755)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, grok_home: grok_home, arb: arb}
  end

  test "default: GROK_AUTH_PROVIDER_COMMAND is a generated wrapper around `arb grok-token`",
       ctx do
    assert {:ok, env} = AuthProvider.spawn_env(ctx.grok_home, arb_path: ctx.arb)

    {"GROK_AUTH_PROVIDER_COMMAND", command} = List.keyfind(env, "GROK_AUTH_PROVIDER_COMMAND", 0)
    assert {"XAI_API_KEY", false} = List.keyfind(env, "XAI_API_KEY", 0)

    # Under the worker's own GROK_HOME, so it survives the jail's `--tmpfs /tmp`.
    assert String.starts_with?(command, ctx.grok_home <> "/")
    assert Bitwise.band(File.stat!(command).mode, 0o777) == 0o755

    # It is a bare path (no argv to mis-split), holds no credential, and runs
    # `arb grok-token` with grok's environment.
    refute command =~ " "
    assert File.read!(command) =~ "grok-token"

    assert {out, 0} = System.cmd(command, [], env: [{"GROK_AUTH_EXPIRED", "1"}])
    assert out =~ "arb-called grok-token expired=1"
  end

  test "an XAI_API_KEY ref replaces the broker; no provider command is set", ctx do
    System.put_env("ARBITER_TEST_XAI_KEY", "xai-test-key")
    on_exit(fn -> System.delete_env("ARBITER_TEST_XAI_KEY") end)

    assert {:ok, env} =
             AuthProvider.spawn_env(ctx.grok_home,
               arb_path: ctx.arb,
               api_key_ref: "env:ARBITER_TEST_XAI_KEY"
             )

    assert {"XAI_API_KEY", "xai-test-key"} = List.keyfind(env, "XAI_API_KEY", 0)

    assert {"GROK_AUTH_PROVIDER_COMMAND", false} =
             List.keyfind(env, "GROK_AUTH_PROVIDER_COMMAND", 0)

    assert File.ls!(ctx.grok_home) == []
  end

  test "a configured ref that does not resolve is an error, not a silent fallback", ctx do
    assert {:error, {:api_key_unresolved, "env:ARBITER_TEST_NOPE"}} =
             AuthProvider.spawn_env(ctx.grok_home,
               arb_path: ctx.arb,
               api_key_ref: "env:ARBITER_TEST_NOPE"
             )
  end

  test "a workspace secret: ref resolves through the config map", ctx do
    config = Arbiter.Agents.CredentialsRef.embed_secrets(%{}, %{"xai" => "xai-secret-value"})

    assert {:ok, env} =
             AuthProvider.spawn_env(ctx.grok_home,
               arb_path: ctx.arb,
               api_key_ref: "secret:xai",
               config: config
             )

    assert {"XAI_API_KEY", "xai-secret-value"} = List.keyfind(env, "XAI_API_KEY", 0)
  end

  test "no arb binary to wrap is an error", ctx do
    assert {:error, :arb_not_found} =
             AuthProvider.spawn_env(ctx.grok_home, arb_path: Path.join(ctx.grok_home, "missing"))
  end

  test "the env never carries a refresh token or a canonical auth path", ctx do
    {:ok, env} = AuthProvider.spawn_env(ctx.grok_home, arb_path: ctx.arb)
    names = Enum.map(env, &elem(&1, 0))

    refute "GROK_REFRESH_TOKEN" in names
    refute Enum.any?(env, fn {_k, v} -> is_binary(v) and v =~ "auth.json" end)
  end
end
