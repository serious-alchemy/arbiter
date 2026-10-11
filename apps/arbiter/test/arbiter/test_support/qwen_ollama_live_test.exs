defmodule Arbiter.Test.QwenOllamaLiveTest do
  # Live smoke: the real qwen CLI against a local Ollama. Excluded from the default
  # suite and CI; opt in with
  #
  #     cd apps/arbiter && mix test --include live_ollama test/arbiter/test_support/qwen_ollama_live_test.exs
  #
  # Env: OLLAMA_URL (default http://127.0.0.1:11434), ARB_LIVE_OLLAMA_MODEL (default qwen2.5-coder).
  use ExUnit.Case, async: false

  @moduletag :live_ollama
  @moduletag :tmp_dir

  alias Arbiter.Test.QwenCli

  test "qwen answers through a local Ollama", %{tmp_dir: dir} do
    base = System.get_env("OLLAMA_URL", "http://127.0.0.1:11434")
    model = System.get_env("ARB_LIVE_OLLAMA_MODEL", "qwen2.5-coder")

    assert is_binary(QwenCli.executable()), "qwen is not on PATH"

    assert Req.get!(base <> "/api/tags", retry: false).status == 200,
           "Ollama not reachable at #{base}"

    {out, status} =
      QwenCli.run("Reply with the single word: pong",
        cwd: dir,
        base_url: base <> "/v1",
        api_key: "ollama",
        model: model,
        timeout: 180_000
      )

    assert status == 0, out
    assert String.downcase(out) =~ "pong"
  end
end
