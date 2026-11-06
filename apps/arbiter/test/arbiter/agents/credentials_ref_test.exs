defmodule Arbiter.Agents.CredentialsRefTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.CredentialsRef

  @env_var "ARBITER_CREDREF_TEST_TOKEN"

  setup do
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  describe "resolve/2 — env:" do
    test "resolves a set env var" do
      System.put_env(@env_var, "tok-123")
      assert {:ok, "tok-123"} = CredentialsRef.resolve("env:" <> @env_var, %{})
    end

    test "reports the var name when unset" do
      System.delete_env(@env_var)
      assert {:env_unset, @env_var} = CredentialsRef.resolve("env:" <> @env_var, %{})
    end

    test "treats an empty env var as unset" do
      System.put_env(@env_var, "")
      assert {:env_unset, @env_var} = CredentialsRef.resolve("env:" <> @env_var, %{})
    end
  end
  describe "resolve/2 — external secret-manager refs" do
    setup do
      dir = Path.join(System.tmp_dir!(), "credref-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{tmp_dir: dir}
    end

    test "file: resolves like env:/secret:", %{tmp_dir: dir} do
      path = Path.join(dir, "tok")
      File.write!(path, "file-token\n")
      assert {:ok, "file-token"} = CredentialsRef.resolve("file:" <> path, %{})
    end

    test "a failing external ref is tagged, carries the pointer, and never a value", %{
      tmp_dir: dir
    } do
      ref = "file:" <> Path.join(dir, "missing")

      assert {:external_error, ^ref, {:file, :enoent}} = CredentialsRef.resolve(ref, %{})

      msg = CredentialsRef.describe_failure({:external_error, ref, {:file, :enoent}})
      assert msg =~ ref
    end

    test "env:NAME falls through to NAME_REF, which wins over an inline NAME", %{tmp_dir: dir} do
      path = Path.join(dir, "tok")
      File.write!(path, "from-pointer")
      System.put_env(@env_var <> "_REF", "file:" <> path)
      on_exit(fn -> System.delete_env(@env_var <> "_REF") end)

      assert {:ok, "from-pointer"} = CredentialsRef.resolve("env:" <> @env_var, %{})

      System.put_env(@env_var, "inline")
      assert {:ok, "from-pointer"} = CredentialsRef.resolve("env:" <> @env_var, %{})
    end

    test "a bad NAME_REF is an external error, not a silent fall-back to NAME" do
      System.put_env(@env_var, "inline")
      System.put_env(@env_var <> "_REF", "not-a-pointer")
      on_exit(fn -> System.delete_env(@env_var <> "_REF") end)

      assert {:external_error, "not-a-pointer", :invalid_ref} =
               CredentialsRef.resolve("env:" <> @env_var, %{})
    end
  end

  describe "resolve/2 — secret:" do
    test "resolves from embedded secrets" do
      raw =
        CredentialsRef.embed_secrets(%{"credentials_ref" => "secret:tracker_token"}, %{
          "tracker_token" => "sct_abc"
        })

      assert {:ok, "sct_abc"} = CredentialsRef.resolve("secret:tracker_token", raw)
    end

    test "reports the key when the secret is absent" do
      raw = CredentialsRef.embed_secrets(%{}, %{"other" => "x"})

      assert {:secret_not_found, "tracker_token"} =
               CredentialsRef.resolve("secret:tracker_token", raw)
    end

    test "reports not_found when no secrets are embedded (raw-map callers)" do
      assert {:secret_not_found, "tracker_token"} =
               CredentialsRef.resolve("secret:tracker_token", %{})
    end

    test "an empty secret value is treated as not found" do
      raw = CredentialsRef.embed_secrets(%{}, %{"tracker_token" => ""})

      assert {:secret_not_found, "tracker_token"} =
               CredentialsRef.resolve("secret:tracker_token", raw)
    end
  end

  describe "resolve/2 — literal / missing" do
    test "a bare string is a literal token" do
      assert {:ok, "literal-token"} = CredentialsRef.resolve("literal-token", %{})
    end

    test "nil / empty / non-string is :missing" do
      assert :missing = CredentialsRef.resolve(nil, %{})
      assert :missing = CredentialsRef.resolve("", %{})
      assert :missing = CredentialsRef.resolve(123, %{})
    end
  end

  describe "embed_secrets/2 + secrets/1" do
    test "round-trips a string→string map and ignores non-string entries" do
      raw = CredentialsRef.embed_secrets(%{}, %{"a" => "1", "b" => 2, 3 => "c"})
      assert CredentialsRef.secrets(raw) == %{"a" => "1"}
    end

    test "treats nil / NotLoaded as no secrets" do
      assert CredentialsRef.secrets(CredentialsRef.embed_secrets(%{}, nil)) == %{}
      assert CredentialsRef.secrets(CredentialsRef.embed_secrets(%{}, %Ash.NotLoaded{})) == %{}
    end

    test "embedded secrets do not collide with string config keys" do
      raw =
        CredentialsRef.embed_secrets(%{"credentials_ref" => "secret:k", "host" => "h"}, %{
          "k" => "v"
        })

      assert Map.get(raw, "host") == "h"
      assert Map.get(raw, "credentials_ref") == "secret:k"
    end
  end
end
