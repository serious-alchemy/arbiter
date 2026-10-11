# Qwen test harness (bd-96ddf6, Q9)

Deterministic tests for the qwen CLI, plus an opt-in live smoke test.

| Piece | Where |
| --- | --- |
| Scripted OpenAI-compatible server (`tool_calls`, SSE, 4xx/5xx/429, sleep steps) | `apps/arbiter/test/support/scripted_openai.ex`, `scripted_openai/router.ex` |
| Server self-tests (no qwen needed) | `apps/arbiter/test/arbiter/test_support/scripted_openai_test.exs` |
| Real qwen CLI against the fixtures (`@tag :qwen_cli`) | `.../test_support/qwen_cli_test.exs`, runner in `test/support/qwen_cli.ex` |
| Live smoke against local Ollama (`@tag :live_ollama`) | `.../test_support/qwen_ollama_live_test.exs` |

`:live_ollama` is excluded in `test_helper.exs`, so the default suite and CI skip it.
`:qwen_cli` is excluded wherever `qwen` is not on `PATH` (CI), and runs where it is.

## Pinned qwen version

`Arbiter.Test.QwenCli.pinned_version/0` — currently **0.25.0**. qwen's flags churn
quickly (bd-3km00p §13), so `qwen_cli_test.exs` fails when the installed version
differs. **Caveat:** the harness was authored on a host without qwen installed, so
the pin and the flags in `QwenCli.run/2` (`--auth-type openai --yolo --bare -p`,
`OPENAI_*` env) have not yet been run against a real binary. The first run on a host
with qwen must confirm or correct them.

## Re-running the fixtures after a qwen upgrade

    cd apps/arbiter
    qwen --version
    mix test --include qwen_cli test/arbiter/test_support/qwen_cli_test.exs

Fix any flag/output drift in `QwenCli.run/2` or the fixtures, then bump `@pinned_version`
in `test/support/qwen_cli.ex` in the same commit.

## Live Ollama smoke

    ollama pull qwen2.5-coder
    cd apps/arbiter
    mix test --include live_ollama test/arbiter/test_support/qwen_ollama_live_test.exs

Env: `OLLAMA_URL` (default `http://127.0.0.1:11434`), `ARB_LIVE_OLLAMA_MODEL`.

## Adapter and stream fixtures (bd-1cm12v, Q2)

`Arbiter.Agents.Qwen` (argv, prompt delivery, env) and `Arbiter.Agents.Qwen.Stream`
(stream quirks, exit-code → `StopReason` table) are covered by
`test/arbiter/agents/qwen_test.exs` and `test/arbiter/agents/qwen/stream_test.exs`,
which replay `test/fixtures/qwen/*.jsonl`. Those fixtures are **hand-authored from
the documented stream-json schema, not live captures** (no qwen binary or hosted
endpoint was available). On the first host with qwen, re-record them from a real
`qwen -o stream-json` run against the scripted server and confirm the exit codes
53/55 (budget, no `result` line) and the argv flags (`-o stream-json --yolo --bare
--auth-type openai --max-session-turns`) before relying on them.
