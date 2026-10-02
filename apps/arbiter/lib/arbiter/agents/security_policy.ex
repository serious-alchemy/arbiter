defmodule Arbiter.Agents.SecurityPolicy do
  @moduledoc """
  The normalized, **provider-agnostic** security posture for a worker run.

  A worker (implementer or reviewer) is an autonomous coding agent spawned in a
  git worktree. Left unconfigured it silently inherits the host operator's
  global agent config — on the Claude provider that means the operator's
  personal `~/.claude/settings.json` (historically `defaultMode: auto`, an
  **empty deny list**) and an **un-sandboxed** run with full filesystem and
  network reach. A wedged live server traced to exactly that posture
  (2026-06-03) is what this module exists to prevent.

  This struct is the single normalized shape every provider adapter maps to
  its own mechanism. It names *intent* ("auto mode, deny destructive ops,
  scope the filesystem to the worktree"), never provider syntax. The Claude
  adapter (`Arbiter.Agents.Claude.Security`) translates it into
  `--permission-mode` / `--settings` / `--dangerously-skip-permissions`; a
  future adapter (antigravity, Codex, …) maps the *same* struct to its own
  flags. See `docs/worker-security.md` and the harness design
  (`docs/agent-harness-design.md`, bd-c6xf18).

  ## Shape

      %Arbiter.Agents.SecurityPolicy{
        permissions: %{
          mode: :auto | :strict | :bypass,
          allow: [String.t()],          # operator-added allow rules (adapter-interpreted)
          deny:  [String.t()],          # operator-added deny rules (adapter-interpreted)
          safe_defaults: [atom()],      # resolved: safe_default_categories() -- safe_defaults_exclude
          safe_defaults_exclude: [atom()] # categories explicitly dropped by name
        },
        sandbox: %{
          enabled: boolean(),
          filesystem: :worktree | :none,
          network: boolean(),
          writable_paths: [String.t()],  # extra paths writable inside the OS jail
          egress_tunnels: [String.t()],  # "LOCAL:HOST:PORT" host services bridged into the jail netns
          egress: :open | :allowlist | :none, # how much of the network a jailed run can reach
          allow_hosts: [String.t()]      # operator baseline "host:port" entries for the egress proxy
        }
      }

  `egress_tunnels` (bd-cfktou) only matters where the worker's jail runs in
  its own network namespace (agy's network mode, see
  `Arbiter.Worker.Egress.JailRun`): each `"LOCAL:HOST:PORT"` entry makes
  `127.0.0.1:LOCAL` inside the jail reach `HOST:PORT` from the host, by a
  fixed-destination bridge (the destination is not the agent's to choose). It is
  how a workspace keeps a host-loopback service its tests need (say Postgres,
  `"5432:127.0.0.1:5432"`) once the jail has no shared network. Malformed
  entries are dropped; the layers union, like `writable_paths`. Read it with
  `egress_tunnels/1`.

  ### `sandbox.egress` and `sandbox.allow_hosts` (bd-5yydxh)

  The policy half of network egress enforcement
  (`docs/design/guardrail-profiles.md` §4.4 and §7.2). `egress` is how much of
  the network a jailed run can reach:

    * `:open` (the default) — no host filtering. Nothing changes for a
      workspace that does not opt in.
    * `:allowlist` — only the run's allowlist: infra, toolchain, extras and
      ticket grants (see below).
    * `:none` — infra and toolchain only, so the agent keeps its model API and
      the ticket's git remote and the build can still fetch its dependencies,
      and nothing else, ticket grants included.

  The four host classes and the levels they are reachable at
  (`egress_classes/1`, `egress_class_allowed?/2`):

  | Class | Contents | Reachable at |
  |---|---|---|
  | `:infra` | The adapter's API hosts, Arbiter, the ticket's git remote | `:none`, `:allowlist` |
  | `:toolchain` | Registries the build needs (`allow_host_class/1`) | `:none`, `:allowlist` |
  | `:extras` | Every other `allow_hosts` entry | `:allowlist` |
  | `:grants` | A ticket's `network:` grants | `:allowlist` |

  `allow_hosts` is the operator-written baseline: exact `host:port`, a leading
  `*.` allowed (`Arbiter.Worker.Egress.Policy.normalize_baseline/1`). It is
  classified per entry, so one list feeds both `:toolchain` and `:extras`.
  `egress_baseline/2` is what the proxy gets.

  Layering follows `permissions.mode`'s layers (installation, workspace, repo,
  dispatch) but is a separate field: `egress` is a scalar the highest layer
  replaces, `allow_hosts` unions like `allow` and `deny`. Setting `mode` never
  moves `egress`. The tighten-only guardrail floor that composes both is G11.
  Unknown values are ignored on resolve (the inherited level survives) and
  refused on write by `Arbiter.Tasks.Workspace.Changes.ValidateConfig`.

  ### `permissions.mode`

    * `:bypass` — the headless-safe default. The interactive permission
      classifier is skipped entirely (`--dangerously-skip-permissions`) so
      there is no approval prompt that can freeze a headless worker.
      The **deny list is still enforced** via `--settings` — the deny list is
      a hard block at the tool level, orthogonal to the interactive classifier.
      This is the right default for autonomous, headless worker runs where
      worktree containment + the deny list are the real fence.
    * `:auto`   — opt-in for interactive/supervised runs. The permission
      classifier is active (`--permission-mode auto`): edits are auto-accepted
      but the classifier can pause and ask for approval. The deny list is also
      enforced. **Do not use as the worker default**: in headless `--print`
      mode, a classifier prompt that can't be answered freezes the run
      silently.
    * `:strict` — only explicitly allowed tools run; anything not on the
      allow-list is blocked (in non-interactive `--print` mode "ask" collapses
      to "deny"). Deny still enforced.

  ### `permissions.safe_defaults`

  The baseline destructive-operation categories every adapter must deny — the
  "non-empty deny even in `auto`" guarantee. Each adapter expands a category
  into its own concrete rules. Categories:

    * `:no_destructive_fs`  — recursive force-deletes (`rm -rf`, …).
    * `:no_force_push`      — `git push --force` / `-f`.
    * `:no_secret_reads`    — reading `.env`, private keys, `~/.ssh`, cloud creds.
    * `:no_outside_writes`  — writing to sensitive paths outside the worktree.
    * `:no_pr_create`       — opening a PR/MR from the worker (`gh pr create`,
      `glab mr create`). The MergeQueue owns PR creation; a worker that opens its
      own PR produces a duplicate on the wrong base (bd-53xrmi).
    * `:no_async_wait`      — `Monitor` / `ScheduleWakeup`. These tools yield a
      turn and resume it when a later event fires, which only works in an
      interactive session. `claude --print` ends the whole process the instant
      a turn produces no tool call, so a worker that arms one ends its turn
      "waiting" and is never woken — the notification has nowhere to arrive
      (bd-d534xo). Denying the tools outright backs the prompt guidance that
      says the same thing.
    * `:no_public_upload`   — network access to public, anonymous file and
      paste hosts (`public_upload_hosts/0`). An agy worker uploaded mockup
      "screenshots" to files.catbox.moe to satisfy an acceptance criterion it
      could not meet (bd-80talz). Such a host takes repo content, logs or
      secrets just as easily, anonymously and usually for good.
    * `:no_gh_publish`      — `gh gist create`/`edit` and `gh issue comment`.
      The same worker made a public gist on the operator's account and posted
      a test comment (bd-80talz). `gh pr comment` is left alone because the
      review-thread follow-up protocol uses it. Workers only:
      `interactive_session_base/0` leaves it out, since an operator or
      coordinator session commenting on an issue is ordinary work.

  Enforced in **every** mode including `:bypass`: `Arbiter.Agents.Claude.Security`
  expands them into the deny document, and `--settings` carries that document
  even when `--dangerously-skip-permissions` is passed. What `:bypass` skips is
  the interactive classifier, not the deny list.

  ### `permissions.safe_defaults_exclude` (bd-4420va)

  The **only** supported way to drop a category from `safe_default_categories/0`
  by name. Each layer's exclude list **unions** onto the previous (like
  `allow`/`deny`) — once a layer excludes a category it stays excluded unless
  a later config edit removes it from the exclude list. The resolved
  `permissions.safe_defaults` is always `safe_default_categories() --
  safe_defaults_exclude`.

  The legacy `permissions.safe_defaults` config key (a literal, replacing
  list) is still read without error, but is **inert**: it no longer narrows
  the resolved set. It used to — a workspace that pinned a subset (say, the 4
  categories that existed before v0.1.78 added 4 more) silently never
  resolved a category added after it pinned, with nothing surfacing the gap
  (vstim missed `:no_public_upload`, `:no_pr_create`, `:no_async_wait` and
  `:no_gh_publish` this way). No manual migration is required: an old pinned
  `safe_defaults` list keeps parsing, it just no longer excludes anything —
  every current default category applies unless separately named in
  `safe_defaults_exclude`. `arb server doctor` / `arb prime` name any category
  a workspace's resolved policy excludes (`SecurityPolicy.summary/1`'s
  `"safe_defaults_exclude"` key), so an exclusion is always visible rather
  than silent.

  ### `sandbox`

  Normalized isolation intent. `filesystem: :worktree` keeps file access
  scoped to the worktree the agent was handed; `network: false` cuts the
  agent's network-egress tools. Adapters enforce this with whatever their
  provider supports — for Claude that is permission rules + directory scoping
  (a permission-level guard, *not* a kernel jail; full OS isolation is a
  documented follow-up). The field is also surfaced verbatim so the operator
  can see the declared posture.

  `writable_paths` (bd-5gvqgc) only matters where a worker runs inside the
  OS write jail (`Arbiter.Worker.Jail`, agy under `:strict` today): each entry
  (absolute, or `~/…`) is bound writable on top of the otherwise read-only
  filesystem. It is the operator's escape hatch for a toolchain cache the
  per-worker `HEX_HOME`/`MIX_HOME`/`XDG_CACHE_HOME` do not cover. Every
  writable shared path is also a way for a jailed worker to leave something
  behind that runs later outside the jail (a shared `~/.mix/archives` runs in
  the operator's own mix commands), so keep the list short. It **unions**
  across layers like `allow`/`deny`.

  ## Resolution

  `resolve/3` layers, lowest precedence first:

    1. `base/0` — the hardcoded safe baseline (this module).
    2. `Application.get_env(:arbiter, :worker_security_policy)` — the
       install-wide default override.
    3. **`workspace.config["agent"]["security"]` — the CANONICAL per-domain
       (workspace-wide) posture.** This is the documented, stable config path.
       The `permissions.mode` value is read from
       `workspace.config["agent"]["security"]["permissions"]["mode"]`.
       (Legacy paths `workspace.config["security"]["mode"]` and
       `workspace.config["agent"]["config"]["security_mode"]` are accepted for
       backward compatibility but are deprecated; new configs must use the
       canonical path.)
    4. `workspace.config["agent"]["security"]["repos"][repo]` — a per-repo
       override *within* the domain, applied only when a `repo` name is passed.
       This lets a multi-repo workspace run one repo under a different posture
       (e.g. a stricter `mode`, an extra deny rule, or `sandbox.network: false`)
       without touching the others. The `"repos"` key is inert for `merge/2`
       (which reads only `permissions`/`sandbox`), so a workspace that never
       sets it — the common case — resolves exactly as before.
    5. an explicit per-dispatch / per-task `override` map.

  For `permissions.allow` / `permissions.deny` / `permissions.safe_defaults_exclude`
  / `sandbox.writable_paths` each layer **unions** onto the previous (a domain adds to the baseline
  rather than dropping it) — so a repo override *adds* allow/deny rules, or
  further exclusions, on top of the workspace posture. `mode` and every
  other `sandbox` field are **replaced** by the highest layer that sets them. The
  legacy `permissions.safe_defaults` key is inert (see above) — it is parsed
  but never changes the resolved set. Unknown / malformed values are ignored
  (the codebase reads JSON config leniently), so a typo degrades to the safer
  inherited value rather than raising.
  """

  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Worker.Egress.Policy, as: EgressPolicy

  @enforce_keys [:permissions, :sandbox]
  defstruct [:permissions, :sandbox]

  @type mode :: :auto | :strict | :bypass
  @type filesystem :: :worktree | :none
  @type egress :: :open | :allowlist | :none
  @type egress_class :: :infra | :toolchain | :extras | :grants

  @type t :: %__MODULE__{
          permissions: %{
            mode: mode(),
            allow: [String.t()],
            deny: [String.t()],
            safe_defaults: [atom()],
            safe_defaults_exclude: [atom()]
          },
          sandbox: %{
            enabled: boolean(),
            filesystem: filesystem(),
            network: boolean(),
            writable_paths: [String.t()],
            egress_tunnels: [String.t()],
            egress: egress(),
            allow_hosts: [String.t()]
          }
        }

  @valid_modes [:auto, :strict, :bypass]
  # Loosest first, so `:open` is the default and a "tighter" level sorts later.
  @valid_egress [:open, :allowlist, :none]
  # Design §4.4: which host classes each level can reach.
  @egress_classes %{
    open: [:infra, :toolchain, :extras, :grants],
    allowlist: [:infra, :toolchain, :extras, :grants],
    none: [:infra, :toolchain]
  }
  # Registries a build fetches from. An `allow_hosts` entry on one of these
  # (or a subdomain) is `:toolchain`; everything else is `:extras`.
  @toolchain_hosts ~w(
    hex.pm
    repo.hex.pm
    builds.hex.pm
    registry.npmjs.org
    pypi.org
    files.pythonhosted.org
    crates.io
    index.crates.io
    static.crates.io
    proxy.golang.org
    sum.golang.org
    rubygems.org
  )
  @valid_filesystems [:worktree, :none]
  @safe_default_categories [
    :no_destructive_fs,
    :no_force_push,
    :no_secret_reads,
    :no_outside_writes,
    :no_pr_create,
    :no_async_wait,
    :no_public_upload,
    :no_gh_publish
  ]

  # bd-80talz: public, anonymous upload and paste hosts. Each entry is a bare
  # registrable domain; every adapter derives its subdomain coverage from it
  # (Claude `WebFetch(domain:*.<host>)`, agy `read_url(<host>)`, which agy
  # 1.2.11 matched against files.catbox.moe). That is why litterbox
  # (litter.catbox.moe) is covered by `catbox.moe` and not listed apart.
  @public_upload_hosts ~w(
    catbox.moe
    0x0.st
    transfer.sh
    file.io
    envs.sh
    x0.at
    temp.sh
    tmpfiles.org
    uguu.se
    bashupload.com
    oshi.at
    keep.sh
    filebin.net
    pixeldrain.com
    gofile.io
    pastebin.com
    paste.ee
    paste.rs
    dpaste.com
    dpaste.org
    hastebin.com
    termbin.com
    ix.io
    sprunge.us
    rentry.co
    controlc.com
    justpaste.it
    privatebin.net
    imgur.com
    imgbb.com
    postimages.org
  )

  # bd-aspkyr: hosts the egress proxy denies under `:no_public_upload` on top
  # of the anonymous upload/paste list. `gist.github.com` is a public paste
  # host that the permission layer reaches through `:no_gh_publish`; the proxy
  # sees only the CONNECT host, so it must be named here. It is separate from
  # `@public_upload_hosts` because every adapter derives a `WebFetch` /
  # `read_url` deny from that list.
  @egress_extra_denied_hosts ~w(gist.github.com)

  @doc "Valid `permissions.mode` atoms."
  @spec valid_modes() :: [mode()]
  def valid_modes, do: @valid_modes

  @doc "Valid `sandbox.filesystem` atoms."
  @spec valid_filesystems() :: [filesystem()]
  def valid_filesystems, do: @valid_filesystems

  @doc "Valid `sandbox.egress` atoms, loosest first."
  @spec valid_egress_levels() :: [egress()]
  def valid_egress_levels, do: @valid_egress

  @doc "The baseline destructive-op categories an adapter must deny by default."
  @spec safe_default_categories() :: [atom()]
  def safe_default_categories, do: @safe_default_categories

  @doc """
  The public upload/paste hosts the `:no_public_upload` category denies, as
  bare domains. Each adapter covers subdomains too (see the moduledoc).
  """
  @spec public_upload_hosts() :: [String.t()]
  def public_upload_hosts, do: @public_upload_hosts

  @doc """
  Every host the egress proxy (`Arbiter.Worker.Egress`) denies under
  `:no_public_upload`: `public_upload_hosts/0` plus hosts only the proxy can
  see (`gist.github.com`). Subdomains are covered too.
  """
  @spec egress_deny_hosts() :: [String.t()]
  def egress_deny_hosts, do: @public_upload_hosts ++ @egress_extra_denied_hosts

  @doc """
  The hardcoded safe baseline: `bypass` mode (headless-safe — no interactive
  classifier freeze), the full destructive-op deny baseline, worktree-scoped
  filesystem, network on (workers need it for `git push` / package installs),
  no operator extras. See `permissions.mode` in the moduledoc for rationale.
  """
  @spec base() :: t()
  def base do
    %__MODULE__{
      permissions: %{
        mode: :bypass,
        allow: [],
        deny: [],
        safe_defaults: @safe_default_categories,
        safe_defaults_exclude: []
      },
      sandbox: %{
        enabled: true,
        filesystem: :worktree,
        network: true,
        writable_paths: [],
        egress_tunnels: [],
        egress: :open,
        allow_hosts: []
      }
    }
  end

  @doc """
  The install-wide default: `base/0` overlaid with
  `Application.get_env(:arbiter, :worker_security_policy)`. This is the floor
  used whenever no workspace policy is in play (ad-hoc ReviewGate runs, bare
  `ClaudeSession.start/1` callers).
  """
  @spec default() :: t()
  def default do
    merge(base(), Application.get_env(:arbiter, :worker_security_policy, %{}))
  end

  @doc """
  The baseline for an **interactive coordinator session** — a real TUI on a
  real PTY with a human at the keyboard (`Arbiter.Sessions`), not a headless
  `claude --print` worker.

  Two things separate it from `base/0`, and both follow from that one
  difference (bd-5xlkkj):

    * `mode: :auto` rather than `:bypass`. `:bypass` exists because a headless
      run freezes on a permission prompt nobody can answer; a session *has*
      somebody to answer, so the classifier is a working guard rather than a
      hang, and running it also spares the operator the "WARNING: Claude Code
      running in Bypass Permissions mode" acceptance screen on every first
      launch.
    * `:no_async_wait` is dropped. `Monitor` and `ScheduleWakeup` are denied to
      workers because `--print` ends the process the instant a turn produces no
      tool call, so a wakeup has no session left to arrive in (bd-d534xo). In a
      session the turn *is* interactive and the wakeup does arrive — `Monitor`
      is how a coordinator session watches the `/events` stream
      (`docs/monitoring.md`).

  Everything else is deliberately unchanged: the destructive-fs, force-push,
  secret-read and outside-write denies all apply, and so does `:no_pr_create`
  (the MergeQueue still owns PR creation — bd-53xrmi — and a hand-rolled
  `gh pr create` from a coordinator console produces the same duplicate on the
  same wrong base).

  It also denies `Bash(arb mcp token mint:*)` (bd-5b5hq7). A session's own MCP
  token is already deliberately weaker than a full coordinator token —
  `can_dispatch: false` by default, possibly workspace-bound, and revoked when
  the session ends. The rule stops the session from even trying to trade up
  for a full-power token by running the CLI. The server-side boundaries are
  `ArbiterWeb.Api.McpController.mint_token/2`, which caps a bearer caller at
  its own authority and refuses anonymous callers outright, and
  `Arbiter.MCP.OperatorSocket`, which refuses any process the server spawned
  and any process inside a session's `arb-session-<id>` scope (bd-8381tk).
  """
  @spec interactive_session_base() :: t()
  def interactive_session_base do
    base = base()
    excluded = [:no_async_wait, :no_gh_publish]

    %{
      base
      | permissions: %{
          base.permissions
          | mode: :auto,
            safe_defaults: @safe_default_categories -- excluded,
            safe_defaults_exclude: excluded,
            deny: base.permissions.deny ++ ["Bash(arb mcp token mint:*)"]
        }
    }
  end

  @doc """
  `interactive_session_base/0` overlaid with
  `Application.get_env(:arbiter, :session_security_policy)`.

  A **separate** config key from `:worker_security_policy` on purpose: the two
  postures are no longer the same document, and an install that hardened its
  headless workers must not silently drag an interactive session back to
  `bypassPermissions` (or vice versa).
  """
  @spec interactive_session() :: t()
  def interactive_session do
    merge(
      interactive_session_base(),
      Application.get_env(:arbiter, :session_security_policy, %{})
    )
  end

  @doc """
  Resolve the effective policy for a workspace (or `nil`), with an optional
  per-dispatch `override` map applied last and an optional `repo` name that
  pulls in a per-repo override layer. See the moduledoc for precedence.

  `repo` is the workspace's `repo_paths` key (e.g. `"tonic_device"`), the same
  identifier the merger per-repo overrides key on. `nil`/`""` disables the
  repo layer, so `resolve/2` behaves exactly as before.
  """
  @spec resolve(map() | nil, map(), String.t() | nil) :: t()
  def resolve(workspace, override \\ %{}, repo \\ nil)

  def resolve(nil, override, _repo), do: merge(default(), override)

  def resolve(%{__struct__: _, config: config}, override, repo),
    do: resolve_from_config(config, override, repo)

  def resolve(%{"config" => config}, override, repo),
    do: resolve_from_config(config, override, repo)

  def resolve(%{config: config}, override, repo),
    do: resolve_from_config(config, override, repo)

  def resolve(_other, override, _repo), do: merge(default(), override)

  @doc """
  Like `resolve/3`, but also names which layer set the effective
  `permissions.mode` — the dispatch-time `override`, a `repos.<repo>`
  override, the workspace default, or the install-wide default
  (`Application.get_env(:arbiter, :worker_security_policy)`).

  Used to name "the scope that made it strict" in the write-confinement
  dispatch refusal (bd-1abj7u) — an operator debugging a refused dispatch
  needs to know WHICH config layer to change, not just that the resolved
  mode was `:strict`.
  """
  @spec mode_source(map() | nil, map(), String.t() | nil) ::
          {mode(), :dispatch_override | :repo | :workspace | :install_default}
  def mode_source(workspace, override \\ %{}, repo \\ nil)

  def mode_source(nil, override, _repo) do
    mode_and_source([
      {:install_default, Application.get_env(:arbiter, :worker_security_policy, %{})},
      {:dispatch_override, override}
    ])
  end

  def mode_source(%{__struct__: _, config: config}, override, repo),
    do: mode_source_from_config(config, override, repo)

  def mode_source(%{"config" => config}, override, repo),
    do: mode_source_from_config(config, override, repo)

  def mode_source(%{config: config}, override, repo),
    do: mode_source_from_config(config, override, repo)

  def mode_source(_other, override, _repo) do
    mode_and_source([
      {:install_default, Application.get_env(:arbiter, :worker_security_policy, %{})},
      {:dispatch_override, override}
    ])
  end

  defp mode_source_from_config(config, override, repo) do
    workspace_policy = effective_workspace_policy(config)
    repo_policy = repo_override(workspace_policy, repo)

    mode_and_source([
      {:install_default, Application.get_env(:arbiter, :worker_security_policy, %{})},
      {:workspace, workspace_policy},
      {:repo, repo_policy},
      {:dispatch_override, override}
    ])
  end

  # Walks the layers in precedence order (same order `merge/2` is folded in
  # `resolve/3`) and remembers the last one that actually names a mode —
  # mirrors `parse_mode/2`'s "nil keeps the fallback" rule so the reported
  # source always matches what `resolve/3` would have resolved to.
  defp mode_and_source(layers) do
    Enum.reduce(layers, {base().permissions.mode, :install_default}, fn {source, raw}, acc ->
      case get(sub_map(raw, :permissions), :mode) do
        nil ->
          acc

        value ->
          case to_atom(value) do
            m when m in @valid_modes -> {m, source}
            _ -> acc
          end
      end
    end)
  end

  # Pre-existing complexity 17 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  defp resolve_from_config(config, override, repo) do
    workspace_policy = effective_workspace_policy(config)
    repo_policy = repo_override(workspace_policy, repo)

    default()
    |> merge(workspace_policy)
    |> merge(repo_policy)
    |> merge(override)
  end

  # The workspace's own security block, with the deprecated alt-mode paths
  # folded into the canonical `permissions.mode` slot when the canonical path
  # is unset. Shared by `resolve/3` and `mode_source/3` so the two can never
  # disagree about what the workspace layer resolved to.
  #
  # Pre-existing complexity 17 — baselined when bd-4x2yhq first wired Credo
  # up (moved here from `resolve_from_config/3` by bd-1abj7u's mode_source/3
  # refactor, which is the function that actually carries the complexity now).
  # Thresholds stay at the tool's own default so new code is held to it; see
  # the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp effective_workspace_policy(config) do
    config = config || %{}
    workspace_policy = get_in(config, ["agent", "security"]) || %{}

    # Check if the canonical path has a mode set
    canonical_mode_set? =
      case get_in(workspace_policy, ["permissions", "mode"]) do
        m when is_binary(m) or (is_atom(m) and not is_nil(m)) -> true
        _ -> false
      end

    # DEPRECATED paths (backward compatibility only):
    # - workspace.config["security"]["mode"]
    # - workspace.config["agent"]["config"]["security_mode"]
    # These are accepted for backward compat ONLY when the canonical path is not set.
    # Canonical path is workspace.config["agent"]["security"]["permissions"]["mode"].
    # If the canonical path is set, it takes precedence over these deprecated paths.
    alt_mode =
      unless canonical_mode_set? do
        case get_in(config, ["security", "mode"]) do
          m when is_binary(m) or (is_atom(m) and not is_nil(m)) ->
            m

          _ ->
            case get_in(config, ["agent", "config", "security_mode"]) do
              m when is_binary(m) or (is_atom(m) and not is_nil(m)) -> m
              _ -> nil
            end
        end
      end

    # If a deprecated alt path set the mode (and canonical was not set), merge it into canonical location.
    workspace_policy =
      if alt_mode do
        Map.update(workspace_policy, "permissions", %{"mode" => alt_mode}, fn perms ->
          Map.put(perms, "mode", alt_mode)
        end)
      else
        workspace_policy
      end

    workspace_policy
  end

  # The per-repo override sub-map nested under the workspace security block:
  # `config["agent"]["security"]["repos"][repo]`. Returns `%{}` (a no-op merge
  # layer) when no `repo` is given or the workspace declares no override for it,
  # so single-repo / un-overridden workspaces resolve unchanged.
  defp repo_override(_workspace_policy, repo) when repo in [nil, ""], do: %{}

  defp repo_override(workspace_policy, repo) when is_binary(repo) do
    repos = get_in(workspace_policy, ["repos"]) || %{}

    case RepoConfig.find_entry(repos, repo) do
      %{} = override -> override
      _ -> %{}
    end
  end

  defp repo_override(_workspace_policy, _repo), do: %{}

  @doc """
  Overlay a raw (string- or atom-keyed) map onto a policy. List fields
  (`allow` / `deny`) union; scalar fields replace. Used internally by
  `resolve/2`; exposed for adapter tests.
  """
  @spec merge(t(), map() | nil) :: t()
  def merge(%__MODULE__{} = policy, nil), do: policy
  def merge(%__MODULE__{} = policy, raw) when raw == %{}, do: policy

  def merge(%__MODULE__{} = policy, raw) when is_map(raw) do
    perms = sub_map(raw, :permissions)
    sandbox = sub_map(raw, :sandbox)

    %__MODULE__{
      permissions: merge_permissions(policy.permissions, perms),
      sandbox: merge_sandbox(policy.sandbox, sandbox)
    }
  end

  defp merge_permissions(base, raw) do
    exclude =
      union(base.safe_defaults_exclude, parse_category_list(get(raw, :safe_defaults_exclude)))

    %{
      mode: parse_mode(get(raw, :mode), base.mode),
      allow: union(base.allow, list_of_strings(get(raw, :allow))),
      deny: union(base.deny, list_of_strings(get(raw, :deny))),
      safe_defaults: @safe_default_categories -- exclude,
      safe_defaults_exclude: exclude
    }
  end

  defp merge_sandbox(base, raw) do
    %{
      enabled: parse_bool(get(raw, :enabled), base.enabled),
      filesystem: parse_filesystem(get(raw, :filesystem), base.filesystem),
      network: parse_bool(get(raw, :network), base.network),
      writable_paths:
        union(Map.get(base, :writable_paths, []), list_of_strings(get(raw, :writable_paths))),
      egress_tunnels:
        union(
          Map.get(base, :egress_tunnels, []),
          raw
          |> get(:egress_tunnels)
          |> list_of_strings()
          |> Enum.filter(&match?({:ok, _}, parse_tunnel(&1)))
        ),
      egress: parse_egress(get(raw, :egress), Map.get(base, :egress, :open)),
      allow_hosts:
        union(
          Map.get(base, :allow_hosts, []),
          raw |> get(:allow_hosts) |> list_of_strings() |> Enum.filter(&valid_allow_host?/1)
        )
    }
  end

  @doc """
  `%{repo => level}`: the effective `sandbox.egress` (as a string) for every
  repo with an `agent.security.repos.<repo>` override. A repo with no override
  resolves like the workspace, so it is not listed.
  """
  @spec repo_egress(term()) :: %{String.t() => String.t()}
  def repo_egress(workspace) do
    repos =
      case workspace do
        %{config: %{} = config} -> get_in(config, ["agent", "security", "repos"])
        _ -> nil
      end

    if is_map(repos) do
      Map.new(repos, fn {repo, _override} ->
        {repo, workspace |> resolve(%{}, repo) |> egress() |> Atom.to_string()}
      end)
    else
      %{}
    end
  end

  @doc """
  The host classes reachable at `egress` (design §4.4). `:open` is not
  filtered at all, so every class is reachable.
  """
  @spec egress_classes(egress()) :: [egress_class()]
  def egress_classes(egress) when egress in @valid_egress, do: Map.fetch!(@egress_classes, egress)

  @doc "True when a host in `class` is reachable at `egress`."
  @spec egress_class_allowed?(egress(), egress_class()) :: boolean()
  def egress_class_allowed?(egress, class), do: class in egress_classes(egress)

  @doc "True when `egress` filters hosts at all (`:allowlist` and `:none`), false for `:open`."
  @spec egress_filtered?(egress()) :: boolean()
  def egress_filtered?(egress) when egress in @valid_egress, do: egress != :open

  @doc """
  The class of one operator `allow_hosts` entry: `:toolchain` for a package
  registry (or a subdomain, or a `*.` wildcard over one), `:extras` otherwise.
  """
  @spec allow_host_class(String.t()) :: :toolchain | :extras
  def allow_host_class(entry) when is_binary(entry) do
    host =
      entry
      |> String.trim()
      |> String.replace_prefix("*.", "")
      |> String.split(":")
      |> List.first()
      |> String.downcase()
      |> String.trim_trailing(".")

    if Enum.any?(@toolchain_hosts, &(host == &1 or String.ends_with?(host, "." <> &1))),
      do: :toolchain,
      else: :extras
  end

  @doc """
  The baseline `host:port` list the egress proxy should run with for `policy`:
  `infra` (always, at `:allowlist` and `:none`) plus the `allow_hosts` entries
  whose class the level reaches. `:unfiltered` at `:open`, where the proxy is
  not the boundary.
  """
  @spec egress_baseline(t(), [String.t()]) :: [String.t()] | :unfiltered
  def egress_baseline(%__MODULE__{sandbox: sandbox}, infra) do
    egress = Map.get(sandbox, :egress, :open)

    if egress_filtered?(egress) do
      hosts =
        Enum.filter(
          Map.get(sandbox, :allow_hosts, []),
          &egress_class_allowed?(egress, allow_host_class(&1))
        )

      union(infra, hosts)
    else
      :unfiltered
    end
  end

  @doc "True when `policy`'s egress level honours a ticket's `network:` grants."
  @spec grants_allowed?(t()) :: boolean()
  def grants_allowed?(%__MODULE__{sandbox: sandbox}),
    do: egress_class_allowed?(Map.get(sandbox, :egress, :open), :grants)

  @doc "The resolved `sandbox.egress` of `policy` (`:open` when unset)."
  @spec egress(t()) :: egress()
  def egress(%__MODULE__{sandbox: sandbox}), do: Map.get(sandbox, :egress, :open)

  # An `allow_hosts` entry the proxy would accept as a baseline.
  defp valid_allow_host?(entry),
    do: match?({:ok, _}, EgressPolicy.normalize_baseline([entry]))

  @doc """
  The policy's `sandbox.egress_tunnels` as `{local_port, host, port}` tuples,
  the shape `Arbiter.Worker.Egress.JailRun` takes.
  """
  @spec egress_tunnels(t()) :: [{:inet.port_number(), String.t(), :inet.port_number()}]
  def egress_tunnels(%__MODULE__{sandbox: sandbox}) do
    sandbox
    |> Map.get(:egress_tunnels, [])
    |> Enum.flat_map(fn entry ->
      case parse_tunnel(entry) do
        {:ok, tunnel} -> [tunnel]
        :error -> []
      end
    end)
  end

  # "LOCAL:HOST:PORT", ports 1..65535, a host with no `:` or whitespace.
  defp parse_tunnel(entry) do
    with [local, host, port] <- String.split(entry, ":"),
         {local, ""} when local in 1..65_535 <- Integer.parse(local),
         {port, ""} when port in 1..65_535 <- Integer.parse(port),
         true <- host != "" and not String.match?(host, ~r/\s/) do
      {:ok, {local, host, port}}
    else
      _ -> :error
    end
  end

  # ---- summary (for prime / dashboard / REST) ----------------------------

  @doc """
  A JSON-friendly, string-keyed summary of the resolved policy — the shape
  surfaced by the REST workspace serializer, `arb prime`, and the dashboard.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = p) do
    %{
      "mode" => Atom.to_string(p.permissions.mode),
      "allow" => p.permissions.allow,
      "deny" => p.permissions.deny,
      "safe_defaults" => Enum.map(p.permissions.safe_defaults, &Atom.to_string/1),
      "safe_defaults_exclude" => Enum.map(p.permissions.safe_defaults_exclude, &Atom.to_string/1),
      "egress" => p |> egress() |> Atom.to_string(),
      "sandbox" => %{
        "enabled" => p.sandbox.enabled,
        "filesystem" => Atom.to_string(p.sandbox.filesystem),
        "network" => p.sandbox.network,
        "writable_paths" => Map.get(p.sandbox, :writable_paths, []),
        "egress_tunnels" => Map.get(p.sandbox, :egress_tunnels, []),
        "egress" => p.sandbox |> Map.get(:egress, :open) |> Atom.to_string(),
        "allow_hosts" => Map.get(p.sandbox, :allow_hosts, [])
      }
    }
  end

  @doc """
  A one-line human summary, e.g. `auto · fs=worktree · net=on · 4 safe-default
  denies`. Used by the dashboard badge tooltip and `arb prime`.
  """
  @spec one_line(t()) :: String.t()
  def one_line(%__MODULE__{} = p) do
    deny_count = length(p.permissions.safe_defaults) + length(p.permissions.deny)

    [
      Atom.to_string(p.permissions.mode),
      "fs=#{p.sandbox.filesystem}",
      "net=#{if p.sandbox.network, do: "on", else: "tools-off"}",
      egress_part(egress(p)),
      "#{deny_count} #{if deny_count == 1, do: "deny", else: "denies"}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # ---- parsing helpers ---------------------------------------------------

  # A raw map may carry string keys (JSON workspace config) or atom keys
  # (Application env / programmatic override). `get/2` tries both.
  defp get(raw, key) when is_map(raw) do
    case Map.fetch(raw, key) do
      {:ok, v} -> v
      :error -> Map.get(raw, Atom.to_string(key))
    end
  end

  defp get(_raw, _key), do: nil

  defp sub_map(raw, key) do
    case get(raw, key) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp parse_mode(nil, fallback), do: fallback

  defp parse_mode(value, fallback) do
    case to_atom(value) do
      m when m in @valid_modes -> m
      _ -> fallback
    end
  end

  defp egress_part(:open), do: nil
  defp egress_part(level), do: "egress=#{level}"

  defp parse_egress(nil, fallback), do: fallback

  defp parse_egress(value, fallback) do
    case to_atom(value) do
      e when e in @valid_egress -> e
      _ -> fallback
    end
  end

  defp parse_filesystem(nil, fallback), do: fallback

  defp parse_filesystem(value, fallback) do
    case to_atom(value) do
      f when f in @valid_filesystems -> f
      _ -> fallback
    end
  end

  defp parse_bool(nil, fallback), do: fallback
  defp parse_bool(b, _fallback) when is_boolean(b), do: b
  defp parse_bool("true", _fallback), do: true
  defp parse_bool("false", _fallback), do: false
  defp parse_bool(_other, fallback), do: fallback

  # `safe_defaults_exclude` entries: unknown category names are dropped, not
  # raised — same leniency as everywhere else in this parser. An absent /
  # malformed value contributes nothing (the caller unions onto the inherited
  # exclude set, so this is a no-op layer, not a reset).
  defp parse_category_list(list) when is_list(list) do
    list
    |> Enum.map(&to_atom/1)
    |> Enum.filter(&(&1 in @safe_default_categories))
    |> Enum.uniq()
  end

  defp parse_category_list(_other), do: []

  defp to_atom(v) when is_atom(v), do: v

  defp to_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> nil
  end

  defp to_atom(_), do: nil

  defp list_of_strings(list) when is_list(list),
    do: Enum.filter(list, &(is_binary(&1) and &1 != ""))

  defp list_of_strings(_), do: []

  defp union(a, b), do: Enum.uniq(a ++ b)
end
