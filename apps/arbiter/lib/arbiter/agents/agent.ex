defmodule Arbiter.Agents.Agent do
  @moduledoc """
  Behaviour for the autonomous-agent harness that drives a worker — the
  process that, given a prompt + worktree, writes the code, runs the tests,
  and signals completion with `arb done`.

  Mirrors `Arbiter.Trackers.Tracker` and `Arbiter.Mergers.Merger`: a thin
  behaviour, a dispatcher (`Arbiter.Agents`), one module per backend. Today
  the only adapter is `Arbiter.Agents.Claude`; Phase B of the harness
  design (`docs/agent-harness-design.md`) intentionally ships the seam
  before any second vendor.

  ## Division of responsibility

  The adapter is **stateless** w.r.t. the running OS process — port
  ownership, PubSub broadcast, line-cap buffering, and durable transcript
  capture all stay in the worker / session module. The adapter only:

    * produces an argv (and optionally an env) for the spawn,
    * declares the regex that recognizes `arb done` in its stream,
    * parses each output line into display tuples + an updated session
      state,
    * surfaces the structured usage attrs the worker persists into the
      `Arbiter.Usage.Event` ledger on session exit.

  This keeps adapters small (just the upstream-CLI shape) and the
  port-management code single-sourced.

  ## `opts` passed to `default_argv/2` and `init_session/1`

  A keyword list. Recognized keys (all optional):

    * `:model` — model name (`"haiku" | "sonnet" | "opus"` for Claude). When
      `nil` the adapter falls back to the CLI default — no behavioral change
      for existing workspaces.
    * `:api_key` — concrete credential to inject into the spawn env. The
      caller — `Arbiter.Agents.Claude.Config` for Claude — resolves which
      key (single-key today; round-robin from `api_keys` list in a follow-up).
    * `:config` — adapter-specific extra config (an opaque map).
    * `:timeout_ms` — the caller's own per-pass timeout budget in
      milliseconds (e.g. `Arbiter.Worker.ReviewGate`'s resolved
      `review_gate.timeout_ms`). Adapters whose CLI has its own internal
      print/turn timeout shorter than a caller's budget should honor this so
      the CLI doesn't cut a long turn short before the caller's own deadline
      ever fires (the Gemini adapter maps it to agy's `--print-timeout`).
      Adapters without such a knob ignore it.
    * `:security` — the resolved `Arbiter.Agents.SecurityPolicy` for this
      spawn (permission mode, allow/deny, sandbox). The caller (Dispatch /
      ReviewGate) resolves it from the workspace; the adapter maps it to its
      provider's mechanism. When absent the adapter MUST fall back to
      `SecurityPolicy.default/0` (the install-wide hardened floor) — a spawn is
      never un-permissioned.

  Adapters may read additional keys; unknown keys are ignored.

  ## Security-policy contract

  Every adapter maps the normalized `:security` policy to its provider and
  **MUST enforce a non-empty destructive-op deny baseline** (the policy's
  `permissions.safe_defaults`) in `:auto` and `:strict` modes — never an empty
  deny. Only `:bypass` (explicit opt-in) skips enforcement. The adapter must
  also **not** fall through to the host operator's personal agent config for
  permissions. The Claude adapter does this via
  `Arbiter.Agents.Claude.Security` + a generated `CLAUDE_CONFIG_DIR`
  `settings.json`; a second provider implements the same contract its own way.

  ## `init_session/1` shape

  Returns the per-session state map the worker threads through
  `parse_line/2` and `usage_attrs/1`. Adapters own its shape — callers
  treat it as opaque.

  ## `parse_line/2`

  Given a complete output line and the prior session state, returns a list
  of `{text, arm_done?}` display tuples plus the updated session state.
  Tuples drive PubSub broadcasts and the durable transcript; `arm_done?`
  gates whether `done_sentinel/0` is matched against the tuple (so tool
  *results* that contain the substring "arb done" can't false-complete).

  Returning `[]` is fine: the line is absorbed into the state (e.g. a
  metadata-only stream event) without producing a display line.

  ## `usage_attrs/1`

  Returns the map persisted into `Arbiter.Usage.Event` on session exit.
  An empty map is fine (graceful degradation when the session never
  produced a usage-bearing event — test echo scripts, premature crashes).
  """

  alias Arbiter.Agents.SecurityPolicy

  @typedoc "Adapter-specific per-session state. Opaque to callers."
  @type session_state :: map()

  @typedoc "One display line plus whether `done_sentinel/0` should be matched against it."
  @type display_line :: {text :: String.t(), arm_done? :: boolean()}

  @typedoc "Structured attrs ready for `Arbiter.Usage.Event.create/1`."
  @type usage_attrs :: map()

  @doc """
  Argv to spawn for `prompt`. Adapters may bake in model / streaming flags
  and consult `opts` for per-dispatch overrides (e.g. `:model`).

  Returns `{:ok, argv}` where `argv` is `[exec, arg1, arg2, ...]` (the head
  is resolved by the session-spawn layer via `System.find_executable/1`),
  or `{:error, reason}` if the adapter cannot construct an argv (e.g. CLI
  not on `$PATH`).
  """
  @callback default_argv(prompt :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Environment variables to inject into the spawned subprocess, as a list of
  `{name, value}` tuples (`value = false` removes the env var from the
  inherited environment).

  This is the seam where credential / key rotation lives — adapters that
  rotate keys per-session decide here. Default implementation returns `[]`
  (inherit env unchanged); adapters opt in.
  """
  @callback spawn_env(opts :: keyword()) :: [{String.t(), String.t() | false}]

  @doc """
  Initial per-session state. Called once when the session is opened.
  """
  @callback init_session(opts :: keyword()) :: session_state

  @doc """
  Parse one complete output line into display tuples + an updated session
  state.
  """
  @callback parse_line(session_state, line :: String.t()) ::
              {[display_line], session_state}

  @doc """
  Regex matched against `arm_done?: true` display tuples to detect that
  the agent has signaled completion (`arb done`).
  """
  @callback done_sentinel() :: Regex.t()

  @doc """
  Structured usage attrs to persist into `Arbiter.Usage.Event` on session
  exit. Missing fields are fine (graceful degradation).
  """
  @callback usage_attrs(session_state) :: usage_attrs

  @doc """
  Provider key for ledger rows + dashboards (e.g. `"claude"`).
  """
  @callback provider() :: String.t()

  @doc """
  The concrete model id this adapter would dispatch with, given `opts` (the
  same keyword list passed to `default_argv/2`). Used to stamp the usage ledger
  and dashboards at spawn time — important for providers (e.g. Gemini) whose CLI
  emits no `init` event carrying the model, so the worker can't learn it from
  the stream.

  Returns the resolved model string, or `nil` when the adapter lets the CLI pick
  its own default and can't name it. Optional — adapters whose model is always
  discoverable from the stream (e.g. Claude's `init` event) may omit it.
  """
  @callback resolved_model(opts :: keyword()) :: String.t() | nil

  @doc """
  Returns `true` when this adapter honors the normalized `SecurityPolicy`
  passed in `opts[:security]` — i.e., enforces a non-empty destructive-op deny
  baseline in `:auto`/`:strict` modes and does not fall through to the host
  operator's agent config.

  Defaults to `false` so that adapters added before implementing the security
  contract don't silently claim enforcement. The Claude adapter returns `true`.
  This value is surfaced in the `security_posture.policy_enforced` REST field so
  operators can see whether the declared posture is actually being enforced.
  """
  @callback security_enforced?() :: boolean()

  @doc """
  Direct auth and liveness probe for the adapter (bd-2r42bq).

  When implemented, `Arbiter.Agents.Preflight.check/2` invokes this callback
  before attempting to spawn an external process via `auth_probe_argv/1`. This
  allows adapters that can verify credentials via an API call (such as
  Codex's zero-quota `wham/usage` probe) to avoid executing a model turn or
  spawning subprocesses.

  Answers:
    * `:ok` — credentials and environment are healthy and authenticated;
    * `{:warn, %StopReason{}}` — non-fatal warning (e.g. transient upstream error);
    * `{:error, %StopReason{}}` — authentication failed or CLI unavailable;
    * `:skipped` — direct probe declined; fall back to `auth_probe_argv/1`.

  Optional — adapters that omit it fall through to `auth_probe_argv/1`.
  """
  @callback auth_probe(opts :: keyword()) ::
              :ok
              | {:warn, Arbiter.Worker.StopReason.t()}
              | {:error, Arbiter.Worker.StopReason.t()}
              | :skipped

  @doc """
  Argv for a cheap auth pre-flight probe — a single round-trip that verifies the
  CLI can authenticate (bd-awi4nw). Returns `{:ok, argv}`, or `{:error, reason}`
  when the CLI can't be resolved.

  `Arbiter.Agents.Preflight` runs this through a port (with the adapter's
  `spawn_env/1`) before a wave of workers is dispatched; a clean exit with no
  auth/credit signature means the credentials are valid. Optional — an adapter
  that omits it is treated as unprobeable (pre-flight is skipped, never blocks).
  """
  @callback auth_probe_argv(opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  The async-tool instruction block to embed in reviewer prompts.

  Adapters return provider-appropriate phrasing — Claude reviewers support
  background execution modes; Gemini reviewers must run all tools
  synchronously because the CLI has no native `run_in_background` /
  notification mechanism and stalls when background execution is requested.

  Optional — adapters that omit this callback fall through to a caller-side
  default (the Claude async block), so existing adapters remain unaffected.
  """
  @callback async_tool_instruction() :: String.t()
  @callback async_tool_instruction(String.t(), String.t() | nil, keyword()) :: String.t()

  @doc """
  The harness's OWN fixed markers for "an asynchronous wait is now armed" —
  text this Arbiter build did not write and the model did not choose the
  wording of, emitted when a tool call is backgrounded (up front or after
  blowing its tool timeout), a monitor starts, or a wakeup is booked
  (bd-1zz5mn / bd-606zlr).

  `Arbiter.Worker.StopReason.classify/3` uses this, keyed by the session's
  provider, to recognize a clean exit that happened immediately after the
  agent armed a wait it could never be notified on (`claude --print` and
  `agy`/`gemini` are both non-interactive: the process exits the instant a
  turn produces no tool call). Each provider's CLI wraps this in its own
  wording, so the signature is per-adapter rather than one shared,
  Claude-shaped list — a new adapter (e.g. codex) declares its own instead of
  editing this module's regex.

  Optional — adapters that omit this callback fall back to the Claude
  signature, so existing adapters remain unaffected until they hit the same
  failure mode and add their own markers.
  """
  @callback async_arm_signature() :: Regex.t()

  @doc """
  Whether this adapter can confine a spawn's writes to the worktree under
  the given resolved `Arbiter.Agents.SecurityPolicy` (bd-1abj7u, deciding
  doc `docs/design/agy-strict-write-isolation.md`).

  Answers:

    * `:os_jail` — an OS-level sandbox (bwrap or similar) wraps the spawn so
      the kernel refuses writes outside the worktree, the git common dir,
      and the adapter's own isolated config dir, regardless of what the
      model or the CLI's own permission layer does.
    * `:permission_layer` — the adapter's own permission/deny mechanism is
      the only thing enforcing the boundary, and it has been proven to hold
      (Claude's generated settings + `--permission-mode`).
    * `:none` — nothing confines writes; the process can write anywhere the
      OS user can. This is also the answer when the callback is omitted.

  `Arbiter.Worker.Dispatch` refuses a `:strict`-scoped dispatch to a
  provider that answers `:none` rather than silently downgrading the mode
  or accepting the promise it can't be kept. Automatic provider selection
  (multi-provider pools) skips a `:none` answer for a `:strict` scope and
  tries another configured provider first.

  Optional — a missing callback means `:none`, so an adapter written before
  this gate existed is never mistaken for isolation it doesn't have.
  """
  @callback write_confinement(SecurityPolicy.t()) :: :os_jail | :permission_layer | :none

  @doc """
  Why this adapter's `write_confinement/1` degraded to something weaker than
  the policy asked for, or `nil` when there is nothing to warn about
  (bd-3s82pf — see `docs/design/agy-strict-write-isolation.md`, "Rollout").

  Outside `:strict`, an adapter that can't confine writes on this host just
  runs unconfined rather than refusing (`write_confinement/1` quietly answers
  `:none`), so nothing in the dispatch path itself surfaces the gap. This
  callback is the seam for `arb server doctor` / the workspace posture API to
  show that degradation instead of only ever seeing it as `:none` — which
  also covers "not applicable" (a provider with no jail concept at all, or a
  policy that opted the sandbox off on purpose).

  Optional — a missing callback means no warning ever surfaces for that
  adapter, matching today's silence.
  """
  @callback write_jail_warning(SecurityPolicy.t()) :: String.t() | nil

  @doc """
  Whether this adapter can confine a worker's **network egress** on this host
  under `policy` (`docs/design/guardrail-profiles.md` §3.4, G11): `:os_jail` when
  the spawn runs in an OS network namespace whose only route out is the egress
  proxy, `:none` otherwise. Like `write_confinement/1` it is a capability the
  host answers, never a tier setting: a guardrail profile that needs
  `egress: allowlist | none` makes an adapter that answers `:none` ineligible
  (drop reason `egress_unenforceable`) rather than running it with the network
  open.

  Optional, a missing callback means `:none`.
  """
  @callback egress_confinement(SecurityPolicy.t()) :: :os_jail | :none

  @doc """
  Prepare the current process to make adapter calls for `workspace`.

  Seeds the adapter's per-process config so subsequent calls in this process
  see the workspace's configuration without threading the workspace through
  every call site.

  `workspace` may be `nil`, which clears the per-process config.
  `opts` is a keyword list; recognized keys include `:role` (`:agent | :review_agent`).

  Optional — adapters that carry no per-process config simply omit this callback.
  """
  @callback prepare(workspace :: Arbiter.Tasks.Workspace.t() | map() | nil, opts :: keyword()) ::
              :ok

  @optional_callbacks [
    prepare: 2,
    spawn_env: 1,
    security_enforced?: 0,
    auth_probe: 1,
    auth_probe_argv: 1,
    resolved_model: 1,
    async_tool_instruction: 0,
    async_tool_instruction: 3,
    async_arm_signature: 0,
    write_confinement: 1,
    write_jail_warning: 1,
    egress_confinement: 1
  ]
end
