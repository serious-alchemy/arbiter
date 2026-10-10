defmodule Arbiter.Accounts.LoginRecipesTest do
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.LoginRecipe
  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Test.FakeLoginCli

  @moduletag :tmp_dir

  defp run(provider, args, mode, env, input \\ nil) do
    script = FakeLoginCli.script(provider)

    task =
      Task.async(fn ->
        opts = [env: FakeLoginCli.env(mode) ++ env, stderr_to_stdout: true]

        cmd =
          if input,
            do: "printf '#{input}\\n' | #{script} #{Enum.join(args, " ")}",
            else: "#{script} #{Enum.join(args, " ")} < /dev/null"

        System.cmd("bash", ["-c", cmd], opts)
      end)

    Task.await(task, 10_000)
  end

  describe "registry" do
    test "claude, codex and grok enabled, agy unsupported" do
      assert {:ok, %LoginRecipe{provider: :claude}} = LoginRecipes.fetch(:claude)
      assert {:ok, %LoginRecipe{provider: :codex}} = LoginRecipes.fetch(:codex)
      assert {:ok, %LoginRecipe{provider: :grok}} = LoginRecipes.fetch(:grok)
      assert {:error, :unsupported} = LoginRecipes.fetch(:agy)
      assert {:error, :unknown} = LoginRecipes.fetch(:nope)
      assert Enum.map(LoginRecipes.enabled(), & &1.provider) == [:claude, :codex, :grok]
      assert :agy in LoginRecipes.unsupported()
    end

    test "every recipe carries its command, args and config-dir env" do
      assert %{command: "claude", args: ["auth", "login"], config_dir_env: "CLAUDE_CONFIG_DIR"} =
               LoginRecipes.claude()

      assert %{command: "codex", args: ["login", "--device-auth"], config_dir_env: "CODEX_HOME"} =
               LoginRecipes.codex()

      assert %{args: ["login", "--device-code"], config_dir_env: "GROK_HOME", enabled?: true} =
               LoginRecipes.grok()
    end
  end

  describe "claude patterns" do
    @url "https://claude.com/cai/oauth/authorize?code=true&client_id=FAKE&state=FAKE"
    @osc_screen "Opening browser to sign in…\n" <>
                  "If the browser didn't open, visit: \e]8;;#{@url}\e\\#{@url}\e]8;;\e\\\n" <>
                  "Paste code here if prompted > "

    test "strips OSC-8 and extracts the URL" do
      r = LoginRecipes.claude()
      refute LoginRecipe.strip_ansi(@osc_screen) =~ "\e"
      assert LoginRecipe.extract_url(r, @osc_screen) == @url
    end

    test "OSC-8 with a truncated label yields the link target" do
      r = LoginRecipes.claude()
      screen = "visit: \e]8;;#{@url}\e\\https://claude.com/…\e]8;;\e\\\n"
      assert LoginRecipe.extract_url(r, screen) == @url
    end

    test "detects the code prompt (no trailing newline) and success/failure" do
      r = LoginRecipes.claude()
      assert LoginRecipe.awaiting_code?(r, @osc_screen)
      refute LoginRecipe.awaiting_code?(r, "Opening browser to sign in…\n")
      assert LoginRecipe.success?(r, "\nLogin successful.\n")
      refute LoginRecipe.success?(r, @osc_screen)
      assert LoginRecipe.failure?(r, "Login failed: Invalid code")
      assert LoginRecipe.extract_device_code(r, @osc_screen) == nil
    end

    test "status reads loggedIn from the JSON" do
      r = LoginRecipes.claude()
      assert LoginRecipe.status_ok?(r, 0, ~s({"loggedIn": true}))
      refute LoginRecipe.status_ok?(r, 0, ~s({"loggedIn": false}))
      refute LoginRecipe.status_ok?(r, 1, ~s({"loggedIn": true}))
      refute LoginRecipe.status_ok?(r, 0, "not json")
    end
  end

  describe "codex patterns" do
    @screen """
    Welcome to Codex [v0.153.4]
    OpenAI's command-line coding agent

    Follow these steps to sign in with ChatGPT using device code authorization:

    1. Open this link in your browser and sign in to your account
       https://auth.openai.com/codex/device

    2. Enter this one-time code (expires in 15 minutes)
       ABCD-12345

    Continue only if you started this login in Codex.
    """

    test "extracts the device URL and the code on the next line" do
      r = LoginRecipes.codex()
      assert LoginRecipe.extract_url(r, @screen) == "https://auth.openai.com/codex/device"
      assert LoginRecipe.extract_device_code(r, @screen) == "ABCD-12345"
      refute LoginRecipe.awaiting_code?(r, @screen)
    end

    test "screen text never signals success; status exit code does" do
      r = LoginRecipes.codex()
      refute LoginRecipe.success?(r, @screen)
      assert LoginRecipe.status_ok?(r, 0, "Logged in using ChatGPT")
      refute LoginRecipe.status_ok?(r, 1, "Not logged in")
    end
  end

  describe "grok patterns" do
    test "extracts device URL and code" do
      screen = """
      To sign in, open this URL in your browser:

        https://accounts.x.ai/oauth2/device?user_code=WXYZ-1234

      Confirm this code in your browser:

        WXYZ-1234

      Waiting for authorization...
      """

      r = LoginRecipes.grok()
      assert LoginRecipe.extract_url(r, screen) =~ "https://accounts.x.ai/oauth2/device"
      assert LoginRecipe.extract_device_code(r, screen) == "WXYZ-1234"
      assert r.status_command == nil
      assert r.status_fallback_file == "auth.json"
    end
  end

  describe "fake claude CLI" do
    test "success: prints flow, then succeeds after a line on stdin", %{tmp_dir: dir} do
      {out, 0} = run(:claude, ["auth", "login"], :success, [{"CLAUDE_CONFIG_DIR", dir}], "CODE")
      r = LoginRecipes.claude()
      assert LoginRecipe.extract_url(r, out) == FakeLoginCli.claude_url()
      assert LoginRecipe.awaiting_code?(r, out)
      assert LoginRecipe.success?(r, out)
      assert File.exists?(Path.join(dir, ".credentials.json"))

      {status, 0} =
        run(:claude, ["auth", "status", "--json"], :success, [{"CLAUDE_CONFIG_DIR", dir}])

      assert LoginRecipe.status_ok?(r, 0, status)
    end

    test "failure: prints failure and exits 1", %{tmp_dir: dir} do
      {out, 1} = run(:claude, ["auth", "login"], :failure, [{"CLAUDE_CONFIG_DIR", dir}], "BAD")
      assert LoginRecipe.failure?(LoginRecipes.claude(), out)
      refute File.exists?(Path.join(dir, ".credentials.json"))
    end

    test "hang: never finishes" do
      assert_hangs(:claude, ["auth", "login"], "CODE")
    end
  end

  describe "fake codex CLI" do
    test "success: device flow then exit 0 and credential", %{tmp_dir: dir} do
      {out, 0} = run(:codex, ["login", "--device-auth"], :success, [{"CODEX_HOME", dir}])
      r = LoginRecipes.codex()
      assert LoginRecipe.extract_url(r, out) == FakeLoginCli.codex_url()
      assert LoginRecipe.extract_device_code(r, out) == FakeLoginCli.codex_code()
      {status, code} = run(:codex, ["login", "status"], :success, [{"CODEX_HOME", dir}])
      assert LoginRecipe.status_ok?(r, code, status)
    end

    test "failure: exits 1 with no credential", %{tmp_dir: dir} do
      {out, 1} = run(:codex, ["login", "--device-auth"], :failure, [{"CODEX_HOME", dir}])
      assert LoginRecipe.failure?(LoginRecipes.codex(), out)
      {_, code} = run(:codex, ["login", "status"], :failure, [{"CODEX_HOME", dir}])
      assert code == 1
    end

    test "hang: never finishes" do
      assert_hangs(:codex, ["login", "--device-auth"], nil)
    end
  end

  # Start the fake in hang mode; it must still be running after its banner,
  # and exit 130 once terminated.
  defp assert_hangs(provider, args, input) do
    script = FakeLoginCli.script(provider)

    port =
      Port.open({:spawn_executable, script}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"FAKE_LOGIN_MODE", ~c"hang"}]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    if input, do: Port.command(port, input <> "\n")
    assert_receive {^port, {:data, _banner}}, 5_000
    refute_receive {^port, {:exit_status, _}}, 600
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert_receive {^port, {:exit_status, 130}}, 5_000
  end
end
