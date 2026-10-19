# Worker toolchain: the repo's pinned Elixir/OTP, never the host's

**Task:** bd-3fnqi8 (GitHub #962) · **Code:** `Arbiter.Worker.Toolchain`,
`Arbiter.Worker.Image`

A worker for a repo runs on the Elixir/Erlang **that repo pins**, on every node
type. The host's own `/usr/local/bin/elixir` is never a source. This exists
because a run that passed on a newer host Elixir while CI on the repo's pinned
1.17 failed three rounds (emr-1fhq64, `Enum.sum_by`), and because a host
toolchain upgrade used to be a manual step coupled to every repo's runtime
upgrade.

## How a repo declares its toolchain

`.tool-versions` at the repo root, plain versions only:

    erlang 29.1.1
    elixir 1.20.4-otp-29

* `elixir` is `X.Y[.Z]`, optionally `-otp-N`; `erlang` is a dotted version.
* The OTP major a run must report is `erlang`'s major, else the `-otp-N` suffix.
* Only the first version on a line counts. Anything that is not a plain version
  (`system`, `latest`, `ref:…`, `path:…`, a typo) is **refused**, not ignored:
  it would otherwise fall back to the host or to a default.
* A repo with a `.arbiter/Containerfile` additionally keeps its `FROM
  …elixir:<v>-erlang-<o>` image in step with `.tool-versions`; a disagreement is
  refused when the image is planned (`Toolchain.check_containerfile/2`). A
  `FROM` that cannot be read (a build arg, another base) is not judged.

## Where each kind of run gets it

| Run | Toolchain comes from | Pin read from |
|-----|----------------------|----------------|
| podman sandbox, local | the repo's worker image (`Image.ensure/3`) | default branch's committed `.tool-versions` / `.arbiter/Containerfile` |
| remote node (`worker.placement`) | the same image, built or pulled on the node by the agent | same |
| cluster pod (k8s) | the same image from the node registry | same |
| bwrap sandbox / unsandboxed, on the server's host | `Toolchain.env/3`: pinned install dirs first on `PATH` | the worktree's `.tool-versions` |

Remote nodes only ever run podman-sandboxed runs (`docs/remote-workers-runbook.md`),
so they never touch the node host's Elixir. Host (bwrap/unsandboxed) runs are the
ones that used the host toolchain; those are what `Toolchain.env/3` fixes. It is
applied to:

* the agent's own process (`ClaudeSession.start/1`; so every `mix`/`elixir` the
  agent runs in its shell),
* the pre-push gate (`PrepushCheck`, host executor),
* `run_tests` (`TestRun.host_exec/2`).

Container runs run the gate and tests through the run's own container, so they
already use the image's toolchain.

### Host runs, in detail

1. Read `.tool-versions` from the worktree. No `elixir`/`erlang` line: `PATH` is
   left alone (the one case that is not pinned).
2. Look for `<root>/elixir/<version>/bin/elixir` and `<root>/erlang/<version>/bin/erl`
   under the install roots: mise's `installs` dir (`$MISE_DATA_DIR`, default
   `~/.local/share/mise/installs`), then asdf's (`$ASDF_DATA_DIR`, default
   `~/.asdf/installs`). Override with `config :arbiter, :worker_toolchain_roots`.
3. Missing: `mise install erlang@… elixir@…` on the server host (single-flight,
   30-minute bound, by explicit tool name so no config needs trusting). Disable
   with `config :arbiter, worker_toolchain_provision: false`.
4. Prefix `PATH` with the install `bin` dirs, then run `elixir --version` on that
   `PATH`; it must report the pinned Elixir and OTP major.

The install lives in the mise data dir keyed by version, so every run for that
version shares it, and many versions coexist.

### Fail closed

If the pinned version cannot be provided (not installed and no `mise`, install
failed or timed out, still missing after install, an install that reports a
different runtime, an unsupported pin) the run is **refused** with
`{:toolchain_unavailable, message}`. The message names the pin and the reason and
says the host's elixir was deliberately not used. At the worker spawn that is a
failed spawn; in the gate and in `run_tests` the step does not run and the result
is an error (the gate's existing "a broken check must not strand work" policy
applies: CI is the backstop, but nothing is run on the wrong runtime).

On the image path, an unsupported `elixir`/`erlang` pin and a Containerfile/pin
mismatch fail `Image.plan/3` instead of silently building the configured default
toolchain. A repo with **no** `.tool-versions` and no Containerfile still gets
`config :arbiter, :worker_image_default_toolchain`; pin your repo to avoid that.

## How a runtime upgrade propagates

1. Bump `.tool-versions` (and the Containerfile's `FROM` if the repo has one) in
   one PR.
2. **Container runs:** the image tag is a content hash that includes
   `.tool-versions`, so the next run after the bump merges to the default branch
   builds (or pulls) the new image on its node. Nothing to do on nodes.
3. **Host runs:** the first run on the bumped `.tool-versions` runs `mise install`
   for the new version on the server host (the bumping PR's own gate included,
   since the worktree's pin is read). Nothing to do by hand, provided `mise` is
   on the server's `PATH`.

Not covered: `prebuilt` images (`image.source: prebuilt`) are whatever the repo's
CI published; keeping their tag in step with `.tool-versions` is the
publisher's job.

## Tests

* `apps/arbiter/test/arbiter/worker/toolchain_test.exs`: parsing, selection,
  provisioning, every fail-closed case, Containerfile agreement.
* `claude_session_test.exs`, `prepush_check_test.exs`, `test_run_test.exs`: the
  three host call sites (pinned `PATH` first; unavailable runs nothing).
* `image_test.exs`: unsupported pin and Containerfile mismatch fail the plan.
