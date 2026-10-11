defmodule Arbiter.Test.QwenCli do
  @moduledoc """
  Runs the real `qwen` CLI headlessly against a `Arbiter.Test.ScriptedOpenAI`
  server (or a real OpenAI-compatible endpoint), and records the pinned version
  the fixtures were written against (bd-96ddf6, Q9).

  Re-running the fixtures after a qwen upgrade: see `docs/qwen-test-harness.md`.
  """

  # The qwen CLI release the scripted fixtures are verified against. qwen's flags
  # churn quickly (bd-3km00p §13), so `qwen_cli_test.exs` fails on any other
  # version until the fixtures are re-run and this pin is bumped on purpose.
  @pinned_version "0.25.0"

  @spec pinned_version() :: String.t()
  def pinned_version, do: @pinned_version

  @spec executable() :: String.t() | nil
  def executable, do: System.find_executable("qwen")

  @doc "The installed `qwen --version` (trimmed), or nil when qwen is absent or fails."
  @spec installed_version() :: String.t() | nil
  def installed_version do
    with exe when is_binary(exe) <- executable(),
         {out, 0} <- System.cmd(exe, ["--version"], stderr_to_stdout: true) do
      String.trim(out)
    else
      _ -> nil
    end
  end

  @doc """
  Runs `qwen -p prompt` in `cwd` pointed at `base_url`; returns `{output, exit_status}`.
  Settings/home live under `cwd` so the operator's own qwen config is never read.
  """
  @spec run(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def run(prompt, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    base_url = Keyword.fetch!(opts, :base_url)
    model = Keyword.get(opts, :model, "scripted-model")
    timeout = Keyword.get(opts, :timeout, 60_000)

    env = [
      {"HOME", cwd},
      {"OPENAI_BASE_URL", base_url},
      {"OPENAI_API_KEY", Keyword.get(opts, :api_key, "test-key")},
      {"OPENAI_MODEL", model},
      {"QWEN_CODE_SUPPRESS_YOLO_WARNING", "1"}
    ]

    task =
      Task.async(fn ->
        System.cmd(executable(), ["--auth-type", "openai", "--yolo", "--bare"] ++
            Keyword.get(opts, :extra_args, []) ++ ["-p", prompt],
          cd: cwd,
          env: env,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"timeout after #{timeout}ms", 124}
    end
  end
end
