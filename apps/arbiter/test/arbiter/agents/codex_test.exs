defmodule Arbiter.Agents.CodexTest do
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.SecurityPolicy

  # bd-24qzhd: OPENAI_API_KEY is a worker_env provider credential (see
  # Arbiter.Accounts.Census's allow-list), so it is routinely present in the
  # ambient shell a codex-backed worker runs `mix test` in. Simulate that
  # ambient leak for the whole module — if the per-test `setup` in
  # `describe "spawn_env/1"` below ever stops clearing the var, "returns []"
  # fails exactly as it would on a polluted host, regardless of which host
  # or branch runs it. ExUnit requires setup_all at module scope, not nested
  # in a describe; it is harmless to the other describes here, which don't
  # read OPENAI_API_KEY.
  setup_all do
    prev = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "sk-leaked-ambient-token")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("OPENAI_API_KEY")
        v -> System.put_env("OPENAI_API_KEY", v)
      end
    end)

    :ok
  end

  describe "behaviour" do
    test "module declares the Agent behaviour" do
      behaviours =
        Codex.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
    end

    test "provider/0 returns \"codex\"" do
      assert Codex.provider() == "codex"
    end

    test "done_sentinel/0 matches `arb done` on a word boundary" do
      assert Regex.match?(Codex.done_sentinel(), "work finished\narb done")
      refute Regex.match?(Codex.done_sentinel(), "all set — arb done")
      refute Regex.match?(Codex.done_sentinel(), "arb doneness")
    end

    test "security_enforced?/0 is false (no per-tool deny list like Claude's)" do
      refute Codex.security_enforced?()
    end

    test "write_confinement/1 is :none regardless of mode (bd-1abj7u)" do
      assert Codex.write_confinement(SecurityPolicy.base()) == :none

      strict = %{
        SecurityPolicy.base()
        | permissions: %{SecurityPolicy.base().permissions | mode: :strict}
      }

      assert Codex.write_confinement(strict) == :none
    end

    test "usage_attrs/1 stamps the provider" do
      attrs = Codex.usage_attrs(%{usage: %{tokens_in: 5}})
      assert attrs[:provider] == "codex"
      assert attrs[:tokens_in] == 5
    end
  end

  describe "resolved_model/1" do
    setup do
      Codex.Config.clear()
      on_exit(&Codex.Config.clear/0)
      :ok
    end

    test "uses an explicit :model override verbatim" do
      assert Codex.resolved_model(model: "gpt-5-codex") == "gpt-5-codex"
    end

    test "resolves a :model_tier to a concrete model via the default tier map" do
      assert Codex.resolved_model(model_tier: "premium") == "gpt-5.6-terra"
      assert Codex.resolved_model(model_tier: "standard") == "gpt-5.6-terra"
      assert Codex.resolved_model(model_tier: "economy") == "gpt-5.6-luna"
      assert Codex.resolved_model(model_tier: "flagship") == "gpt-5.6-terra"
    end

    test "returns nil when nothing is configured (CLI picks its own default)" do
      assert Codex.resolved_model([]) == nil
    end

    test "paid-tier accounts resolve to gpt-5.6 models by default" do
      # Paid-tier ChatGPT accounts have access to gpt-5.6-luna and gpt-5.6-terra.
      # These are the default tier models for paid-tier and enterprise accounts.
      defaults = Codex.Config.default_tier_models()

      # Verify the paid-tier defaults
      assert defaults["economy"] == "gpt-5.6-luna"
      assert defaults["standard"] == "gpt-5.6-terra"
      assert defaults["premium"] == "gpt-5.6-terra"
      assert defaults["flagship"] == "gpt-5.6-terra"

      # All tiers resolve correctly with the defaults
      assert Codex.resolved_model(model_tier: "economy") == "gpt-5.6-luna"
      assert Codex.resolved_model(model_tier: "standard") == "gpt-5.6-terra"
      assert Codex.resolved_model(model_tier: "premium") == "gpt-5.6-terra"
      assert Codex.resolved_model(model_tier: "flagship") == "gpt-5.6-terra"
    end

    test "free-tier accounts fall back to gpt-5.5 when plan_type is set" do
      # Free-tier ChatGPT accounts only have access to gpt-5.4-mini and gpt-5.5.
      # When plan_type is detected and stored in the config, tier resolution
      # returns free-tier models instead of the paid-tier defaults.
      free_tier_config = %{"plan_type" => "free"}

      # Plan-aware defaults should return free-tier models
      free_defaults = Codex.Config.plan_aware_defaults(free_tier_config)
      assert free_defaults["economy"] == "gpt-5.5"
      assert free_defaults["standard"] == "gpt-5.5"
      assert free_defaults["premium"] == "gpt-5.5"
      assert free_defaults["flagship"] == "gpt-5.5"

      # Simulate free-tier workspace config
      Codex.Config.put_active(free_tier_config)

      # All tiers should resolve to gpt-5.5 for free-tier
      assert Codex.resolved_model(model_tier: "economy") == "gpt-5.5"
      assert Codex.resolved_model(model_tier: "standard") == "gpt-5.5"
      assert Codex.resolved_model(model_tier: "premium") == "gpt-5.5"
      assert Codex.resolved_model(model_tier: "flagship") == "gpt-5.5"
    end
  end

  describe "default_argv/2 executable resolution" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-codex-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp, old_path: old_path}
    end

    defp stub_codex(tmp) do
      codex = Path.join(tmp, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)
      codex
    end

    test "returns {:error, ...} when `codex` is not on PATH", %{old_path: old_path} do
      System.put_env("PATH", "/nonexistent-dir-for-test")

      try do
        assert {:error, {:executable_not_found, "codex"}} = Codex.default_argv("hello", [])
      after
        System.put_env("PATH", old_path)
      end
    end

    test "builds a `codex exec --json` invocation wrapped for closed stdin", %{tmp: tmp} do
      codex = stub_codex(tmp)

      assert {:ok, argv} = Codex.default_argv("the prompt", [])
      assert ["sh", "-c", script, "sh", ^codex, "exec" | rest] = argv
      assert script =~ "< /dev/null"
      assert "--json" in rest
      # The prompt is the final positional, delimited by `--` so a prompt that
      # starts with `-` is never parsed as a flag.
      assert List.last(argv) == "the prompt"
      assert "--" in rest
    end

    test ":bypass security mode bypasses approvals and the sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      bypass = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: bypass)
      assert "--dangerously-bypass-approvals-and-sandbox" in argv
      refute "-s" in argv
    end

    test ":strict security mode maps to a read-only sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      strict = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: strict)
      assert chunk_after(argv, "-s") == "read-only"
      refute "--dangerously-bypass-approvals-and-sandbox" in argv
    end

    test ":auto security mode maps to a workspace-write sandbox", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      auto = SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :auto}})
      assert {:ok, argv} = Codex.default_argv("the prompt", security: auto)
      assert chunk_after(argv, "-s") == "workspace-write"
      refute "--dangerously-bypass-approvals-and-sandbox" in argv
    end

    test "passes through `:model` opt as `-m <name>`", %{tmp: tmp} do
      _codex = stub_codex(tmp)

      assert {:ok, argv} = Codex.default_argv("the prompt", model: "gpt-5-codex")
      assert chunk_after(argv, "-m") == "gpt-5-codex"
    end

    test "large prompts are delivered via stdin, not spliced into argv", %{tmp: tmp} do
      codex = stub_codex(tmp)

      big = String.duplicate("x", 200_000)
      assert {:ok, argv} = Codex.default_argv(big, [])
      # The oversize prompt is NOT an argv element (would blow MAX_ARG_STRLEN).
      refute big in argv
      # Instead a temp file is threaded and `-` tells codex to read stdin.
      assert Enum.any?(argv, &(is_binary(&1) and String.contains?(&1, "arb_codex_prompt_")))
      assert ["sh", "-c", script, "sh" | _] = argv
      assert script =~ ~s(< "$f") or script =~ "$f"
      assert ^codex = Enum.find(argv, &(&1 == codex))
    end
  end

  defp chunk_after(list, flag) do
    list
    |> Enum.drop_while(&(&1 != flag))
    |> Enum.at(1)
  end

  describe "spawn_env/1" do
    setup do
      Codex.Config.clear()
      prev_key = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      on_exit(fn ->
        Codex.Config.clear()

        case prev_key do
          nil -> System.delete_env("OPENAI_API_KEY")
          v -> System.put_env("OPENAI_API_KEY", v)
        end
      end)

      :ok
    end

    test "exports OPENAI_API_KEY from `opts[:api_key]`" do
      assert {"OPENAI_API_KEY", "sk-test"} in Codex.spawn_env(api_key: "sk-test")
    end

    test "returns [] when no api key is configured (ambient ChatGPT auth via CODEX_HOME)" do
      assert Codex.spawn_env([]) == []
    end
  end

  describe "auth_probe_argv/1" do
    setup do
      tmp =
        Path.join(System.tmp_dir!(), "arbiter-codex-probe-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      codex = Path.join(tmp, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)
      prev_probe = Application.get_env(:arbiter, :codex_argv_probe)
      Application.put_env(:arbiter, :codex_argv_probe, true)
      on_exit(fn -> restore_env(:codex_argv_probe, prev_probe) end)
      {:ok, codex: codex}
    end

    test "fails closed when the argv probe is disabled" do
      Application.put_env(:arbiter, :codex_argv_probe, false)
      assert {:error, {:executable_not_found, _}} = Codex.auth_probe_argv([])
    end

    test "returns a cheap `codex exec` round-trip", %{codex: codex} do
      assert {:ok, argv} = Codex.auth_probe_argv([])
      assert ["sh", "-c", _script, "sh", ^codex, "exec" | _rest] = argv
    end
  end

  describe "auth_probe/1" do
    setup do
      prev_http_stub = Application.get_env(:arbiter, :codex_quota_http_stub)
      Application.put_env(:arbiter, :codex_quota_http_stub, true)
      Codex.Config.clear()
      prev_key = System.get_env("OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      tmp =
        Path.join(System.tmp_dir!(), "arbiter-codex-probe-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", tmp)

      codex = Path.join(tmp, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)

      on_exit(fn ->
        restore_env(:codex_quota_http_stub, prev_http_stub)
        Codex.Config.clear()

        case prev_key do
          nil -> System.delete_env("OPENAI_API_KEY")
          v -> System.put_env("OPENAI_API_KEY", v)
        end

        System.put_env("PATH", old_path)
        File.rm_rf!(tmp)
      end)

      {:ok, codex: codex}
    end

    test "returns :ok when usage API returns 200" do
      Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn ->
        Req.Test.json(conn, %{"plan_type" => "plus"})
      end)

      assert :ok = Codex.auth_probe(credentials: %{access_token: "tok-123", account_id: nil})
    end

    test "returns :skipped (defers to argv probe, no hard expiry) when usage API returns 401" do
      Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "expired"})
      end)

      # A stale access token must not lock Codex out: the CLI refreshes it.
      assert :skipped =
               Codex.auth_probe(credentials: %{access_token: "tok-123", account_id: nil})
    end

    test "returns :skipped without calling usage API when api_key is provided (falls back to argv probe)" do
      # If an API key is set, it falls back to auth_probe_argv so the key/backend is validated
      assert :skipped = Codex.auth_probe(api_key: "sk-proj-test-key")
    end

    test "honours CODEX_HOME for ChatGPT auth in auth_probe" do
      home_dir =
        Path.join(System.tmp_dir!(), "arbiter_codex_home_#{System.unique_integer([:positive])}")

      File.mkdir_p!(home_dir)

      File.write!(
        Path.join(home_dir, "auth.json"),
        Jason.encode!(%{"tokens" => %{"access_token" => "tok-codex-home"}})
      )

      prev_home = System.get_env("CODEX_HOME")
      prev_cfg = Application.get_env(:arbiter, :codex_quota)

      Application.put_env(:arbiter, :codex_quota, [])
      System.put_env("CODEX_HOME", home_dir)

      on_exit(fn ->
        case prev_home do
          nil -> System.delete_env("CODEX_HOME")
          v -> System.put_env("CODEX_HOME", v)
        end

        case prev_cfg do
          nil -> Application.delete_env(:arbiter, :codex_quota)
          v -> Application.put_env(:arbiter, :codex_quota, v)
        end

        File.rm_rf(home_dir)
      end)

      Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn ->
        assert ["Bearer tok-codex-home"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"plan_type" => "plus"})
      end)

      assert :ok = Codex.auth_probe([])
    end

    test "returns :skipped for a keyless backend with no ChatGPT auth.json (Ollama-style)" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "arbiter_codex_keyless_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      prev_cfg = Application.get_env(:arbiter, :codex_quota)
      Application.put_env(:arbiter, :codex_quota, auth_path: Path.join(dir, "auth.json"))

      on_exit(fn ->
        case prev_cfg do
          nil -> Application.delete_env(:arbiter, :codex_quota)
          v -> Application.put_env(:arbiter, :codex_quota, v)
        end

        File.rm_rf(dir)
      end)

      assert :skipped = Codex.auth_probe([])

      File.write!(Path.join(dir, "auth.json"), Jason.encode!(%{"OPENAI_API_KEY" => nil}))
      assert :skipped = Codex.auth_probe([])
    end

    test "returns {:error, :crashed} when codex binary is not on PATH" do
      System.put_env("PATH", "/nonexistent/bin")
      assert {:error, reason} = Codex.auth_probe([])
      assert reason.category == :crashed
      assert reason.summary =~ "agent CLI not found on PATH"
    end
  end

  describe "prompt_tmpfile/1 and splice_prompt/2" do
    test "prompt_tmpfile/1 extracts the temp file path for stdin-mode argv" do
      argv = [
        "sh",
        "-c",
        "f=\"$1\"; shift; exec \"$@\" < \"$f\"",
        "sh",
        "/tmp/arb_codex_prompt_12345.txt",
        "/path/to/codex",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--",
        "-"
      ]

      assert Codex.prompt_tmpfile(argv) == "/tmp/arb_codex_prompt_12345.txt"
    end

    test "prompt_tmpfile/1 returns nil for inline-mode argv" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--",
        "some prompt"
      ]

      assert Codex.prompt_tmpfile(argv) == nil
    end

    test "splice_prompt/2 replaces prompt for inline-mode argv (nudge)" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "original prompt"
      ]

      assert {:ok, new_argv} = Codex.splice_prompt(argv, ["nudge prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "--json",
               "--",
               "nudge prompt"
             ]
    end

    test "splice_prompt/2 replaces prompt for stdin-mode argv and switches to inline (nudge)" do
      argv = [
        "sh",
        "-c",
        "f=\"$1\"; shift; exec \"$@\" < \"$f\"",
        "sh",
        "/tmp/arb_codex_prompt_12345.txt",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "-"
      ]

      assert {:ok, new_argv} = Codex.splice_prompt(argv, ["nudge prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "--json",
               "--",
               "nudge prompt"
             ]
    end

    test "splice_prompt/2 rebuilds argv for resume" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/path/to/codex",
        "exec",
        "--json",
        "--",
        "original prompt"
      ]

      assert {:ok, new_argv} =
               Codex.splice_prompt(argv, ["--resume", "sess-123", "continue prompt"])

      assert new_argv == [
               "sh",
               "-c",
               "exec \"$@\" < /dev/null",
               "sh",
               "/path/to/codex",
               "exec",
               "resume",
               "--json",
               "--",
               "sess-123",
               "continue prompt"
             ]
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_env(key, val), do: Application.put_env(:arbiter, key, val)
end
