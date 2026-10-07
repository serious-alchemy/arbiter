defmodule Arbiter.Tasks.WorkspaceConfigSafetyTest do
  @moduledoc """
  P-20 (D-C-4/5/15/16/17): the workspace-config safety rails live in the
  `:patch_config` / `:update` / `:create` change chain, so MCP, REST and the CLI
  all get them and none has to re-implement them.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.ConfigPath

  defp workspace(config \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "cfg-safety-#{n}", prefix: "cs", config: config})
    ws
  end

  defp patch(ws, args), do: Ash.update(ws, args, action: :patch_config)

  describe "ConfigPath" do
    test "split/1 honours a backslash-escaped dot" do
      assert ConfigPath.split("a.b.c") == ["a", "b", "c"]
      assert ConfigPath.split("repo_paths.my\\.repo.path") == ["repo_paths", "my.repo", "path"]
      assert ConfigPath.split("a\\\\.b") == ["a\\", "b"]
      assert ConfigPath.split("a..b.") == ["a", "b"]
      assert ConfigPath.split("") == []
    end

    test "join/1 round-trips through split/1" do
      segs = ["repo_paths", "my.repo", "a\\b"]
      assert ConfigPath.split(ConfigPath.join(segs)) == segs
    end

    test "put/3 and get/2 address nested keys" do
      assert ConfigPath.put(%{}, ["a", "b.c"], 1) == %{"a" => %{"b.c" => 1}}
      assert ConfigPath.get(%{"a" => %{"b.c" => 1}}, ["a", "b.c"]) == 1
      assert ConfigPath.get(%{"a" => 1}, ["a", "b"]) == nil
    end
  end

  describe "secret/credentials top-level keys (D-C-4)" do
    @blocked ~w(secrets secret credentials Secrets credentials_ref secret_token)

    test ":patch_config refuses a patch that sets one" do
      ws = workspace(%{"merge" => %{"strategy" => "github"}})

      for key <- @blocked do
        assert {:error, err} = patch(ws, %{patch: %{key => %{"x" => "tok"}}})
        assert Exception.message(err) =~ "arb workspace secret"
      end

      assert Ash.get!(Workspace, ws.id).config == %{"merge" => %{"strategy" => "github"}}
    end

    test ":update refuses a config carrying a new or changed one" do
      ws = workspace(%{"merge" => %{"strategy" => "github"}})

      assert {:error, err} =
               Ash.update(ws, %{config: %{"secrets" => %{"gh" => "ghp_x"}}})

      assert Exception.message(err) =~ "arb workspace secret"
    end

    test ":create refuses one too" do
      assert {:error, _} =
               Ash.create(Workspace, %{name: "cfg-safety-create", config: %{"secrets" => %{}}})
    end

    test "the dedicated `secrets` argument is untouched" do
      ws = workspace()
      assert {:ok, ws} = Ash.update(ws, %{secrets: %{"gh_token" => "ghp_x"}})
      assert Workspace.secrets_map(ws) == %{"gh_token" => "ghp_x"}
    end

    test "unsetting a leaked key stays possible, and a key already stored does not block siblings" do
      ws = workspace()
      # Legacy plaintext that predates the refusal, written around the changes.
      {:ok, ws} =
        ws
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:config, %{"secrets" => %{"gh" => "x"}})
        |> Ash.update()

      assert {:ok, ws} = patch(ws, %{patch: %{"merge" => %{"strategy" => "github"}}})
      assert {:ok, ws} = patch(ws, %{unset_paths: ["secrets.gh"]})
      assert ws.config["secrets"] == %{}
    end
  end

  describe "unset of an absent key (D-C-15)" do
    test "is an idempotent success" do
      ws = workspace(%{"merge" => %{"strategy" => "github"}})
      assert {:ok, same} = patch(ws, %{unset_paths: ["nope.at.all"]})
      assert same.config == ws.config
    end
  end

  describe "dotted keys with an escaped dot (D-C-17)" do
    test "unset_paths reaches a repo name containing a dot" do
      ws = workspace(%{"repo_paths" => %{"my.repo" => "/a", "other" => "/b"}})
      assert {:ok, ws} = patch(ws, %{unset_paths: ["repo_paths.my\\.repo"]})
      assert ws.config["repo_paths"] == %{"other" => "/b"}
    end
  end

  describe "server-side safety rails (D-C-16)" do
    @ok_config %{
      "repo_paths" => %{"arbiter" => "/srv/arbiter"},
      "tracker" => %{"type" => "github", "config" => %{"owner" => "acme"}}
    }

    test "emptying repo_paths is refused unless forced" do
      ws = workspace(@ok_config)

      # unsetting the last repo leaves an empty map ...
      assert {:error, err} = patch(ws, %{unset_paths: ["repo_paths.arbiter"]})
      assert Exception.message(err) =~ "repo_paths is empty"

      # ... and so does dropping the whole section
      assert {:error, err} = patch(ws, %{unset_paths: ["repo_paths"]})
      assert Exception.message(err) =~ "repo_paths"

      assert Ash.get!(Workspace, ws.id).config["repo_paths"] == %{"arbiter" => "/srv/arbiter"}

      assert {:ok, forced} = patch(ws, %{unset_paths: ["repo_paths.arbiter"], force: true})
      assert forced.config["repo_paths"] == %{}
    end

    test "a tracker type with no tracker.config is refused unless forced" do
      ws = workspace()

      assert {:error, err} = patch(ws, %{patch: %{"tracker" => %{"type" => "github"}}})
      assert Exception.message(err) =~ "tracker.config is missing/empty"

      assert {:ok, _} =
               patch(ws, %{patch: %{"tracker" => %{"type" => "github"}}, force: true})
    end

    test "unsetting tracker.config out from under a typed tracker is refused" do
      ws = workspace(@ok_config)
      assert {:error, err} = patch(ws, %{unset_paths: ["tracker.config"]})
      assert Exception.message(err) =~ "tracker.config is missing/empty"
    end

    test "an already-broken config does not block an unrelated edit" do
      ws = workspace()

      {:ok, ws} =
        ws
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:config, %{"tracker" => %{"type" => "github"}})
        |> Ash.update()

      assert {:ok, _} = patch(ws, %{patch: %{"merge" => %{"strategy" => "github"}}})
    end

    test "valid writes are unaffected" do
      ws = workspace(@ok_config)
      assert {:ok, ws} = patch(ws, %{patch: %{"repo_paths" => %{"b" => "/b"}}})
      assert map_size(ws.config["repo_paths"]) == 2
    end
  end
end
