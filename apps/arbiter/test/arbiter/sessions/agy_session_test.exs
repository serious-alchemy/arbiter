defmodule Arbiter.Sessions.AgySessionTest do
  @moduledoc """
  Browser sessions on agy (bd-7xuvfl, agy parity T10).

    * AC1 — `:agy` is a session provider, backed by
      `Arbiter.Sessions.Provider.Agy` and an `agy --prompt-interactive` launch.
    * AC2 — the instructions land as `GEMINI.md`, never `CLAUDE.md`.
    * AC3 — the MCP config lands where agy actually reads it (T2,
      bd-m8geh4: `$HOME/.gemini/config/mcp_config.json`, here the session's
      own `$HOME`) and carries the session's revocable token.
    * AC4 — agy has no config dir: the row's `config_dir` is `nil`, and
      provisioning neither creates nor seeds one.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Provider
  alias Arbiter.Sessions.Provisioning
  alias Arbiter.Sessions.Session
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    env = SessionEnv.sandbox("agy-session")
    SessionRunnerStub.reset()

    {:ok,
     root: env[:sessions_root],
     checkout: env[:primary_checkout],
     source_home: env[:sessions_agy_source_home]}
  end

  # `ensure_reader: false`: the eager transcript reader recreates
  # `<session>/transcript` in the background, which would race `destroy/1`
  # and litter the sessions root after the sandbox is restored.
  defp launch!(opts \\ []) do
    {:ok, session} =
      Sessions.launch(
        Keyword.merge([runner: SessionRunnerStub, provider: :agy, ensure_reader: false], opts)
      )

    session
  end

  defp home_file!(session, rel), do: session.id |> Layout.home_dir() |> Path.join(rel)

  describe "the provider (AC1)" do
    test ":agy is a session provider with its own adapter" do
      assert :agy in Session.providers()
      assert Provider.adapter(:agy) == Provider.Agy
    end

    test "the pane runs the provisioned wrapper, which execs agy --prompt-interactive" do
      session = launch!()
      script = Layout.launch_script_path(session.id)

      assert session.provider == :agy
      assert [{"systemd-run", args, _opts}] = SessionRunnerStub.calls()
      assert List.last(args) == script

      body = File.read!(script)
      assert body =~ "exec agy --prompt-interactive '"
      refute body =~ "exec claude"
      assert body =~ "cd '#{Layout.workspace_dir(session.id)}'"
    end

    test "the pane's HOME is the session's own, and no CLAUDE_CONFIG_DIR is set" do
      session = launch!()
      home = Layout.home_dir(session.id)

      env = Provider.env(session)
      assert {"HOME", home} in env
      assert {"ARB_SESSION_ID", session.id} in env
      refute List.keymember?(env, "CLAUDE_CONFIG_DIR", 0)

      body = File.read!(Layout.launch_script_path(session.id))
      assert body =~ "export HOME='#{home}'"
      refute body =~ "CLAUDE_CONFIG_DIR"
    end

    test "the initial prompt points the agent at its GEMINI.md" do
      session = launch!()
      command = Provisioning.agent_command(session)

      assert command =~ "agy --prompt-interactive '"
      assert command =~ Path.join(Layout.workspace_dir(session.id), "GEMINI.md")
    end

    test "an effort-suffixed model gets no --effort; a bare one does (operator decision)" do
      session = launch!()

      suffixed =
        Provisioning.agent_command(session, model: "gemini-3.1-pro-high", thinking: "high")

      assert suffixed =~ "--model gemini-3.1-pro-high"
      refute suffixed =~ "--effort"

      bare =
        Provisioning.agent_command(session, model: "claude-opus-4-6-thinking", thinking: "high")

      assert bare =~ "--model claude-opus-4-6-thinking"
      assert bare =~ "--effort high"
    end

    test "an operator-supplied name never reaches agy's argv (agy has no --name)" do
      session = launch!(name: "it's; rm -rf ~")

      refute Provisioning.agent_command(session) =~ "--name"
      refute Provisioning.agent_command(session) =~ "rm -rf"
    end

    test "agy refuses mode A and Remote Control at the row" do
      assert {:error, _} =
               Sessions.launch(
                 runner: SessionRunnerStub,
                 provider: :agy,
                 auth_mode: :oauth_token,
                 oauth_token: "tok"
               )

      assert {:error, _} =
               Sessions.launch(runner: SessionRunnerStub, provider: :agy, remote_control: true)
    end
  end

  describe "instructions (AC2)" do
    test "renders GEMINI.md into the cwd and no CLAUDE.md anywhere" do
      session = launch!()
      cwd = Layout.workspace_dir(session.id)

      gemini_md = File.read!(Path.join(cwd, "GEMINI.md"))
      assert gemini_md =~ "coordinator session"
      assert gemini_md =~ "agy"
      refute gemini_md =~ "Claude Code session"
      refute gemini_md =~ ".mcp.json"
      refute gemini_md =~ "Monitor"

      refute File.exists?(Layout.instructions_path(session.id))
      refute File.exists?(Path.join(cwd, "CLAUDE.md"))
    end

    test "the session HOME's own GEMINI.md is session memory, not the headless worker's" do
      session = launch!()
      memory = File.read!(home_file!(session, ".gemini/GEMINI.md"))

      assert memory =~ Path.join(Layout.workspace_dir(session.id), "GEMINI.md")
      refute memory =~ "arb done"
      refute memory =~ "--print"
    end
  end

  describe "MCP config (AC3)" do
    test "lands at $HOME/.gemini/config/mcp_config.json with a revocable session token" do
      session = launch!()
      path = home_file!(session, ".gemini/config/mcp_config.json")

      assert {:ok, %{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0

      %{"mcpServers" => servers} = path |> File.read!() |> Jason.decode!()
      assert [{_name, server}] = Map.to_list(servers)
      assert is_binary(server["serverUrl"])
      refute Map.has_key?(server, "httpUrl")
      "Bearer " <> token = server["headers"]["Authorization"]

      assert {:ok, scope} = Scope.from_token(token)
      assert scope.session_id == session.id
      assert scope.tier == :coordinator

      {:ok, _} = Sessions.revoke_mcp_token(session)
      assert {:error, :revoked} = Scope.from_token(token)
    end

    test "writes no .mcp.json into the cwd" do
      session = launch!()
      refute File.exists?(Layout.mcp_config_path(session.id))
    end

    test "mcp: false writes no MCP config at all" do
      session = launch!(mcp: false)
      refute File.exists?(home_file!(session, ".gemini/config/mcp_config.json"))
    end
  end

  describe "no config dir (AC4)" do
    test "the row has no config_dir and provisioning creates none", %{checkout: checkout} do
      session = launch!()

      assert session.config_dir == nil
      refute File.exists?(Layout.config_dir(session.id))

      assert {:ok, provisioned} = Provisioning.provision(session, primary_checkout: checkout)
      assert provisioned.config_dir == nil
      refute File.exists?(Layout.config_dir(session.id))
    end

    test "the session HOME carries a generated agy posture trusting the cwd and denying the checkout" do
      session = launch!()
      # Resolved, not the sandbox's value: an inherited ARB_PRIMARY_CHECKOUT
      # outranks app config in `Paths`, and provisioning reads the same thing.
      checkout = Arbiter.Config.Paths.primary_checkout()

      settings =
        session
        |> home_file!(".gemini/antigravity-cli/settings.json")
        |> File.read!()
        |> Jason.decode!()

      assert settings["toolPermission"] == "always-proceed"
      assert Layout.workspace_dir(session.id) in settings["trustedWorkspaces"]
      assert "write_file(#{checkout})" in settings["permissions"]["deny"]
    end

    test "passes the operator HOME through without looping back into the sessions root",
         %{root: root, source_home: source_home} do
      File.mkdir_p!(Path.join(source_home, ".config"))
      # The sessions root sitting under the operator's HOME is the default
      # shape (`~/dev/arbiter-sessions`); a flat link to its parent would make
      # the session HOME contain itself.
      nested_root = Path.join([source_home, "dev", "arbiter-sessions"])
      File.mkdir_p!(Path.join(source_home, "dev/other-project"))
      SessionEnv.override(sessions_root: nested_root)

      session = launch!()
      home = Layout.home_dir(session.id)

      assert {:ok, _} = File.read_link(Path.join(home, ".config"))
      assert {:ok, _} = File.read_link(Path.join(home, "dev/other-project"))
      refute File.exists?(Path.join(home, "dev/arbiter-sessions"))
      assert root != nested_root
    end

    # Observed live (agy 1.2.12): a fresh `.gemini` opens `agy -i` on a
    # "Choose your color scheme" onboarding wizard instead of the initial
    # prompt; agy keys it on `cache/onboarding.json`.
    test "carries the operator's agy onboarding state over, so the pane opens on the prompt",
         %{source_home: source_home} do
      onboarding = ~s({"consumerOnboardingComplete": true, "onboardingComplete": true})
      src = Path.join(source_home, ".gemini/antigravity-cli/cache/onboarding.json")
      File.mkdir_p!(Path.dirname(src))
      File.write!(src, onboarding)

      session = launch!()

      assert File.read!(home_file!(session, ".gemini/antigravity-cli/cache/onboarding.json")) ==
               onboarding
    end

    test "never writes onboarding state through a link planted in the session HOME",
         %{source_home: source_home} do
      src = Path.join(source_home, ".gemini/antigravity-cli/cache/onboarding.json")
      File.mkdir_p!(Path.dirname(src))
      File.write!(src, "{}")

      session = launch!()
      elsewhere = Path.join(source_home, "elsewhere")
      File.mkdir_p!(elsewhere)
      cache = home_file!(session, ".gemini/antigravity-cli/cache")
      File.rm_rf!(cache)
      File.ln_s!(elsewhere, cache)

      assert {:ok, _} = Provisioning.provision(session, mcp: false)

      assert File.ls!(elsewhere) == []
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(cache)
    end

    test "destroy removes the session HOME without following its passthrough links",
         %{source_home: source_home} do
      File.mkdir_p!(Path.join(source_home, ".config"))
      File.write!(Path.join(source_home, ".config/keep"), "x")

      session = launch!()
      :ok = Provisioning.destroy(session)

      refute File.exists?(Layout.session_dir(session.id))
      assert File.exists?(Path.join(source_home, ".config/keep"))
    end
  end
end
