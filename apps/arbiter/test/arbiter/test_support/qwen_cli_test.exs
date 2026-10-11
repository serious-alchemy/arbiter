defmodule Arbiter.Test.QwenCliTest do
  # Drives the REAL qwen CLI against the scripted fixture server. Excluded
  # unless `qwen` is on PATH (see test_helper.exs); docs/qwen-test-harness.md.
  use ExUnit.Case, async: true

  @moduletag :qwen_cli
  @moduletag :tmp_dir

  alias Arbiter.Test.{QwenCli, ScriptedOpenAI}

  test "installed qwen matches the pinned version the fixtures were written for" do
    assert QwenCli.installed_version() =~ QwenCli.pinned_version()
  end

  test "a scripted text reply reaches qwen's output", %{tmp_dir: dir} do
    server = ScriptedOpenAI.start_supervised!([{:text, "scripted-pong"}])

    {out, status} = QwenCli.run("say pong", cwd: dir, base_url: server.url)

    assert status == 0, out
    assert out =~ "scripted-pong"
    assert [%{body: %{"messages" => messages}} | _] = ScriptedOpenAI.requests(server)
    assert Enum.any?(messages, &(&1["role"] == "user"))
  end

  test "a scripted tool call is executed and its result sent back", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "note.txt"), "fixture-contents")

    server =
      ScriptedOpenAI.start_supervised!([
        {:tool_calls,
         [%{name: "read_file", arguments: %{"file_path" => Path.join(dir, "note.txt")}}]},
        {:text, "done"}
      ])

    {out, status} = QwenCli.run("read note.txt", cwd: dir, base_url: server.url)

    assert status == 0, out
    assert [_first, second] = ScriptedOpenAI.requests(server)
    assert Enum.any?(second.body["messages"], &(&1["role"] == "tool"))
  end

  # bd-7yj8qv: a run relaunched with `--resume <pre-assigned id>` (what
  # Qwen.splice_prompt/2 builds after a coordinator restart) must reload the
  # first run's history in a fresh qwen process.
  test "a run resumed by its pre-assigned session id carries the first run's history", %{
    tmp_dir: dir
  } do
    sid = Ecto.UUID.generate()
    marker = "remember-the-marker-4242"
    server = ScriptedOpenAI.start_supervised!([{:text, "first-reply"}, {:text, "second-reply"}])

    {out1, status1} =
      QwenCli.run(marker, cwd: dir, base_url: server.url, extra_args: ["--session-id", sid])

    assert status1 == 0, out1

    {:ok, argv} = Arbiter.Agents.Qwen.default_argv(marker, session_id: sid)

    {:ok, ["sh", "-c", _, "sh", _qwen | args]} =
      Arbiter.Agents.Qwen.splice_prompt(argv, ["--resume", sid, "continue"])

    idx = Enum.find_index(args, &(&1 == "--resume"))
    assert Enum.slice(args, idx, 2) == ["--resume", sid]

    {out2, status2} =
      QwenCli.run("continue", cwd: dir, base_url: server.url, extra_args: ["--resume", sid])

    assert status2 == 0, out2
    assert [_first, %{body: %{"messages" => messages}}] = ScriptedOpenAI.requests(server)
    assert Enum.any?(messages, &(is_binary(&1["content"]) and &1["content"] =~ marker))
  end

  test "a 429 then success is retried by qwen", %{tmp_dir: dir} do
    server = ScriptedOpenAI.start_supervised!([{:rate_limit, 1}, {:text, "after-429"}])

    {out, status} = QwenCli.run("hi", cwd: dir, base_url: server.url)

    assert status == 0, out
    assert out =~ "after-429"
  end
end
