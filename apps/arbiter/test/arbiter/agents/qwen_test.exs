defmodule Arbiter.Agents.QwenTest do
  # async: false — PATH is global.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Qwen

  @moduletag :capture_log

  # Hand-authored fixtures, not live captures: see fixtures/qwen/README.md.
  @fixtures Path.expand("../../fixtures/qwen", __DIR__)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "qwen-adapter-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(base, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "qwen"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin, "qwen"), 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(base)
    end)

    {:ok, bin: bin, qwen: Path.join(bin, "qwen")}
  end

  defp run_fixture(name, opts \\ []) do
    session = Qwen.init_session(opts)

    @fixtures
    |> Path.join(name)
    |> File.stream!()
    |> Enum.reduce({[], session}, fn line, {acc, s} ->
      {display, s} = Qwen.parse_line(s, String.trim_trailing(line, "\n"))
      {acc ++ display, s}
    end)
  end

  describe "behaviour" do
    test "implements Agent; provider qwen; sentinel matches `arb done`" do
      behaviours =
        Qwen.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
      assert Qwen.provider() == "qwen"
      assert Regex.match?(Qwen.done_sentinel(), "work finished\narb done")
      refute Regex.match?(Qwen.done_sentinel(), "arb doneness")
    end

    test "does not claim a security layer it does not have yet" do
      refute Qwen.security_enforced?()
    end
  end

  describe "default_argv/2" do
    test "builds the headless stream-json argv with the prompt inline and stdin closed", %{
      qwen: qwen
    } do
      assert {:ok, ["sh", "-c", script, "sh", ^qwen | args]} =
               Qwen.default_argv("do the thing", model: "qwen3-coder:30b")

      assert script =~ ~s(exec "$@" < /dev/null)
      assert Enum.take(args, 2) == ["-p", "do the thing"]
      assert ["-o", "stream-json"] == flag_pair(args, "-o")
      assert "--yolo" in args
      assert ["--auth-type", "openai"] == flag_pair(args, "--auth-type")
      assert ["-m", "qwen3-coder:30b"] == flag_pair(args, "-m")
      assert ["--max-session-turns", "60"] == flag_pair(args, "--max-session-turns")
    end

    test "omits -m without a model and honours :max_turns and :auth_type" do
      assert {:ok, ["sh", "-c", _, "sh", _ | args]} =
               Qwen.default_argv("p", max_turns: 7, auth_type: "anthropic")

      refute "-m" in args
      assert ["--max-session-turns", "7"] == flag_pair(args, "--max-session-turns")
      assert ["--auth-type", "anthropic"] == flag_pair(args, "--auth-type")
    end

    test "a prompt over the argv limit goes through a stdin file, never argv", %{qwen: qwen} do
      big = String.duplicate("x", 140_000)

      assert {:ok, ["sh", "-c", script, "sh", tmp, ^qwen | args]} = Qwen.default_argv(big)

      on_exit(fn -> File.rm(tmp) end)
      assert script =~ ~s(< "$f")
      refute "-p" in args
      assert Enum.all?(args, &(byte_size(&1) < 1000))
      assert File.read!(tmp) == big
      assert Qwen.prompt_tmpfile(["sh", "-c", script, "sh", tmp, qwen | args]) == tmp
      assert Qwen.prompt_tmpfile(["sh", "-c", "s", "sh", qwen, "-p", "x"]) == nil
    end

    test "errors when qwen is not on PATH" do
      System.put_env("PATH", "/nonexistent")
      assert {:error, {:executable_not_found, "qwen"}} = Qwen.default_argv("p")
    end
  end

  describe "spawn_env/1" do
    test "disables colour and the updater, and scrubs inherited credentials" do
      env = Qwen.spawn_env([])
      assert {"NO_COLOR", "1"} in env
      assert {"QWEN_CODE_SUPPRESS_YOLO_WARNING", "1"} in env
      assert {"OPENAI_API_KEY", false} in env
      assert {"OPENAI_BASE_URL", false} in env
    end

    test "an endpoint passed in opts replaces the scrubbed vars" do
      env =
        Qwen.spawn_env(
          endpoint: %{base_url: "http://127.0.0.1:11434/v1", api_key: "ollama"},
          model: "m"
        )

      assert {"OPENAI_BASE_URL", "http://127.0.0.1:11434/v1"} in env
      assert {"OPENAI_API_KEY", "ollama"} in env
      assert {"OPENAI_MODEL", "m"} in env
      refute {"OPENAI_API_KEY", false} in env
    end
  end

  describe "resolved_model/1" do
    test "returns the model or nil" do
      assert Qwen.resolved_model(model: "m") == "m"
      assert Qwen.resolved_model(model: "") == nil
      assert Qwen.resolved_model([]) == nil
    end
  end

  describe "parse_line/2 on the success stream" do
    test "parses into the session model: model, tool use, sentinel, usage" do
      {display, session} = run_fixture("success.jsonl")

      assert Enum.any?(display, fn {l, _} -> l =~ "qwen session started" end)
      assert Enum.any?(display, fn {l, _} -> l =~ "Bash" end)
      assert Enum.any?(display, fn {l, armed?} -> armed? and l =~ "arb done" end)

      usage = Qwen.usage_attrs(session)
      assert usage.provider == "qwen"
      assert usage.tokens_in == 1300
      assert usage.tokens_out == 52
      assert usage.cache_read_tokens == 1200
      assert usage.model == "qwen3-coder:30b"
      assert usage.harness_version == "0.25.0"
    end

    test "tool calls and session lines never arm the done sentinel" do
      {display, _} = run_fixture("success.jsonl")

      for {line, armed?} <- display,
          String.starts_with?(line, "⚙") or line =~ "Bash" do
        refute armed?
      end
    end
  end

  describe "parse_line/2 on budget exits that emit no result line" do
    test "turn limit (exit 53): usage survives from the per-message sums" do
      {display, session} = run_fixture("turn_limit_53.jsonl")
      refute Enum.any?(display, fn {l, _} -> l =~ "session done" or l =~ "session success" end)

      usage = Qwen.usage_attrs(session)
      assert usage.tokens_in == 1000
      assert usage.tokens_out == 55
      assert usage.cache_read_tokens == 900
      refute Map.get(usage, :result_subtype)
    end

    test "token budget (exit 55): same" do
      {_display, session} = run_fixture("budget_55.jsonl")
      usage = Qwen.usage_attrs(session)
      assert usage.tokens_in == 4000
      assert usage.tokens_out == 600
    end
  end

  describe "parse_line/2 on an error result" do
    test "surfaces the error text and records no fake-zero usage" do
      {display, session} = run_fixture("error_result.jsonl")

      assert Enum.any?(display, fn {l, _} -> l =~ "qwen error: 404 model 'nope-model'" end)
      assert Enum.any?(display, fn {l, _} -> l =~ "qwen session error" end)

      usage = Qwen.usage_attrs(session)
      assert usage.is_error == true
      refute usage[:tokens_in]
    end
  end

  defp flag_pair(args, flag) do
    idx = Enum.find_index(args, &(&1 == flag))
    Enum.slice(args, idx, 2)
  end
end
