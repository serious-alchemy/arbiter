defmodule Arbiter.Worker.GitCredentialPlanTest do
  @moduledoc """
  G16 (bd-9cygoo): which git credential a spawn gets, and when a dispatch that
  needs push is refused for want of a scoped one.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.GitCredential

  defp ws(git_credentials), do: %{config: %{"git_credentials" => git_credentials}}

  @key_entry %{"kind" => "deploy_key", "key_secret" => "TONIC_DEPLOY_KEY"}

  describe "plan/3" do
    test "an install with no guardrails and no git_credentials block is unenforced (legacy behaviour)" do
      assert {:ok, %GitCredential{mode: :unenforced}} =
               GitCredential.plan(%{config: %{}}, "tonic", role: :implementer, guarded?: false)
    end

    test "a guarded spawn with no credential for the repo is refused with a clear message" do
      assert {:error, {:git_credential_missing, "tonic", message}} =
               GitCredential.plan(%{config: %{}}, "tonic", role: :implementer, guarded?: true)

      assert message =~ "tonic"
      assert message =~ "git_credentials"
      assert message =~ "legacy_operator"
    end

    test "a workspace with a git_credentials block refuses a repo it does not cover" do
      workspace = ws(%{"repos" => %{"vstim" => @key_entry}})

      assert {:error, {:git_credential_missing, "tonic", _}} =
               GitCredential.plan(workspace, "tonic", role: :implementer, guarded?: false)
    end

    test "a configured repo gets its scoped credential" do
      workspace = ws(%{"repos" => %{"tonic" => @key_entry}})

      assert {:ok, %GitCredential{mode: :scoped, entry: entry}} =
               GitCredential.plan(workspace, "tonic", role: :implementer, guarded?: true)

      assert entry.kind == :deploy_key
      assert entry.key_secret == "TONIC_DEPLOY_KEY"
    end

    test "the repo lookup tolerates a forge-qualified slug and separator differences" do
      workspace = ws(%{"repos" => %{"apex-server" => @key_entry}})

      assert {:ok, %GitCredential{mode: :scoped}} =
               GitCredential.plan(workspace, "acme/apex_server", role: :implementer)
    end

    test "workspace-level legacy_operator is an explicit opt-in" do
      workspace = ws(%{"legacy_operator" => true})

      assert {:ok, %GitCredential{mode: :legacy}} =
               GitCredential.plan(workspace, "tonic", role: :implementer, guarded?: true)
    end

    test "repo-level legacy_operator opts in only that repo" do
      workspace =
        ws(%{"repos" => %{"tonic" => %{"legacy_operator" => true}, "vstim" => @key_entry}})

      assert {:ok, %GitCredential{mode: :legacy}} = GitCredential.plan(workspace, "tonic", [])

      assert {:ok, %GitCredential{mode: :scoped}} = GitCredential.plan(workspace, "vstim", [])
    end

    test "a repo-level legacy_operator: false overrides a workspace-level opt-in" do
      workspace =
        ws(%{"legacy_operator" => true, "repos" => %{"tonic" => %{"legacy_operator" => false}}})

      assert {:error, {:git_credential_missing, "tonic", _}} =
               GitCredential.plan(workspace, "tonic", guarded?: true)
    end

    test "a reviewer never needs push" do
      assert {:ok, %GitCredential{mode: :not_needed}} =
               GitCredential.plan(%{config: %{}}, "tonic", role: :reviewer, guarded?: true)
    end

    test "a spawn the host pushes for needs none" do
      assert {:ok, %GitCredential{mode: :not_needed}} =
               GitCredential.plan(%{config: %{}}, "tonic", guarded?: true, host_pushes?: true)
    end

    test "a nil workspace is unenforced unless guarded" do
      assert {:ok, %GitCredential{mode: :unenforced}} = GitCredential.plan(nil, "tonic", [])
      assert {:error, {:git_credential_missing, _, _}} = GitCredential.plan(nil, "tonic", guarded?: true)
    end
  end

  describe "validate/1" do
    test "accepts each kind" do
      assert :ok =
               GitCredential.validate(%{
                 "legacy_operator" => false,
                 "repos" => %{
                   "a" => @key_entry,
                   "b" => %{"kind" => "token", "token_secret" => "T", "username" => "oauth2"},
                   "c" => %{
                     "kind" => "github_app",
                     "app_id" => "1",
                     "installation_id" => "2",
                     "private_key_secret" => "K"
                   },
                   "d" => %{"legacy_operator" => true}
                 }
               })
    end

    test "refuses an unknown kind, a missing secret name and a bad remote" do
      assert {:error, _} = GitCredential.validate(%{"repos" => %{"a" => %{"kind" => "pat"}}})
      assert {:error, _} = GitCredential.validate(%{"repos" => %{"a" => %{"kind" => "deploy_key"}}})

      assert {:error, _} =
               GitCredential.validate(%{
                 "repos" => %{
                   "a" => %{"kind" => "token", "token_secret" => "T", "remote" => "a b/c"}
                 }
               })

      assert {:error, _} = GitCredential.validate(%{"legacy_operator" => "yes"})
      assert {:error, _} = GitCredential.validate("nope")
    end
  end

  describe "parse_remote/1" do
    test "extracts owner/repo from the usual remote forms" do
      for url <- [
            "git@github.com:acme/tonic.git",
            "https://github.com/acme/tonic",
            "https://x-access-token:abc@github.com/acme/tonic.git",
            "ssh://git@github.com/acme/tonic.git"
          ] do
        assert {:ok, "acme/tonic"} == GitCredential.parse_remote(url), url
      end
    end

    test "rejects what it cannot pin" do
      assert :error = GitCredential.parse_remote("/srv/git/tonic.git")
      assert :error = GitCredential.parse_remote("")
    end
  end
end

defmodule Arbiter.Worker.GitCredentialConfigTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Tasks.Workspace

  defp create(config),
    do: Ash.create(Workspace, %{name: "gcc-#{System.unique_integer([:positive])}", prefix: "gcc", config: config})

  test "a valid git_credentials block is accepted" do
    assert {:ok, _} =
             create(%{
               "git_credentials" => %{
                 "repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "K"}}
               }
             })
  end

  test "an invalid block is refused on write, so a typo cannot read as configured" do
    assert {:error, error} =
             create(%{"git_credentials" => %{"repos" => %{"tonic" => %{"kind" => "pat"}}}})

    assert Exception.message(error) =~ "git_credentials.repos.tonic.kind"

    assert {:error, _} = create(%{"git_credentials" => %{"legacy_operater" => true}})
  end
end
