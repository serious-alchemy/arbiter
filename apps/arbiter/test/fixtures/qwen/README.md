# qwen stream-json fixtures (bd-1cm12v, Q2)

Hand-authored from the documented `qwen -o stream-json` event schema (Claude-style
envelopes: `system/init`, `assistant`, `user`, `result`) plus the quirks in
bd-3km00p §1. They are **not** captures from a live qwen run — no qwen binary or
hosted endpoint was available when they were written. When a host with qwen
exists, re-record them (see `docs/qwen-test-harness.md`) and replace these.

| File | Scenario |
| --- | --- |
| `success.jsonl` | init, a Bash tool round-trip, final text with `arb done`, `result` (success) |
| `turn_limit_53.jsonl` | cut off by the turn budget: assistant lines only, **no `result` line**, exit 53 |
| `budget_55.jsonl` | cut off by the token/session budget: **no `result` line**, exit 55 |
| `error_result.jsonl` | `result` with `is_error: true`, an `error` object and all-zero usage |

Session-JSONL fixtures for the Q7 usage reconcile (`ui_telemetry` / `api_response`
records, the same hand-authored caveat as above):

| File | Scenario |
| --- | --- |
| `success_session.jsonl` | the two API calls behind `success.jsonl`, plus thinking tokens the stream lacks |
| `turn_limit_53_session.jsonl` | the calls behind `turn_limit_53.jsonl`; the last line is torn, as when the process is killed mid-write |
