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

  test "a 429 then success is retried by qwen", %{tmp_dir: dir} do
    server = ScriptedOpenAI.start_supervised!([{:rate_limit, 1}, {:text, "after-429"}])

    {out, status} = QwenCli.run("hi", cwd: dir, base_url: server.url)

    assert status == 0, out
    assert out =~ "after-429"
  end
end
