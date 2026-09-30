defmodule Arbiter.Sessions.LoginKindTest do
  @moduledoc """
  bd-98oj3s (login relay 1/6): `Session.kind` — `:coordinator` (default) or
  `:login`. A login session is hidden from ordinary lists, holds no MCP token,
  cannot dispatch, and runs on its own tmux socket under `arb-login-*` names.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Naming
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    SessionEnv.sandbox("login-kind")
    SessionRunnerStub.reset()
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.merge([runner: SessionRunnerStub], opts))
    session
  end

  defp login!(opts \\ []) do
    launch!(Keyword.merge([kind: :login, login_account: "work@example.com"], opts))
  end

  test "kind defaults to :coordinator" do
    assert launch!().kind == :coordinator
  end

  describe "listing" do
    test "Sessions.list/1 excludes :login by default, includes it on request" do
      coord = launch!()
      login = login!()

      ids = Enum.map(Sessions.list(), & &1.id)
      assert coord.id in ids
      refute login.id in ids

      assert [%{id: id}] = Sessions.list(include_kinds: [:login])
      assert id == login.id

      both = Enum.map(Sessions.list(include_kinds: [:coordinator, :login]), & &1.id)
      assert coord.id in both and login.id in both
    end

    test "the status filter composes with the kind filter" do
      login = login!()
      refute login.id in Enum.map(Sessions.list(status: :running), & &1.id)
      assert [_] = Sessions.list(status: :running, include_kinds: [:login])
    end
  end

  describe "no privileges" do
    test "can_dispatch is forced off even when requested" do
      refute login!(can_dispatch: true).can_dispatch
    end

    test "no MCP token can be minted, and the row is born revoked" do
      login = login!()
      assert login.mcp_token_revoked_at
      assert_raise ArgumentError, fn -> Sessions.mint_mcp_token(login) end

      # A token forged with the login session's id is refused as revoked.
      forged = Scope.mint_session(login.id, can_dispatch: true)
      assert {:error, :revoked} = Scope.from_token(forged)
    end

    test "provisioning writes no .mcp.json into the login session's cwd" do
      login = login!(mcp: true)
      refute File.exists?(Arbiter.Sessions.Layout.mcp_config_path(login.id))
    end
  end

  describe "tmux isolation" do
    test "own socket and arb-login-<account>-<nonce> tmux session name" do
      login = login!()
      coord = launch!()

      name = Naming.tmux_session(login)
      assert name =~ ~r/^arb-login-work-example-com-[0-9a-f]{8}$/
      assert Naming.tmux_session(coord) == "coord"

      assert Path.basename(login.tmux_socket) == name <> ".sock"
      refute Path.basename(login.tmux_socket) =~ ~r/^session-/
      # never matched by the coordinator-socket glob the adoption sweep uses
      {:ok, glob} = Naming.socket_glob()
      assert Path.wildcard(glob) -- [login.tmux_socket] == Path.wildcard(glob)
    end

    test "launch_argv builds the tmux command on that socket and name" do
      login = login!()
      {"systemd-run", args} = Sessions.launch_argv(login)

      assert ["-S", login.tmux_socket, "new-session", "-d", "-s", Naming.tmux_session(login)] ==
               Enum.slice(args, Enum.find_index(args, &(&1 == "-S")), 6)
    end

    test "a :login session requires an account" do
      assert {:error, _} = Sessions.launch(runner: SessionRunnerStub, kind: :login)
    end
  end
end
