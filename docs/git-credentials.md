# Scoped git and tracker credentials (G16, bd-9cygoo)

A worker that pushes uses a credential that reaches **one repo**. It never gets
the operator's ssh-agent or keys, and no worker is ever given a token with the
`gist` or `delete_repo` scope. Design: `docs/design/guardrail-profiles.md` §5.5
and §9 (G16). Mechanism: `Arbiter.Worker.GitCredential`.

## What you (the operator) have to create

Arbiter cannot create these for you. For each repo workers push to, pick one:

| Kind | You create | You register in Arbiter |
|---|---|---|
| `deploy_key` | An SSH keypair (`ssh-keygen -t ed25519 -N '' -f key`), added as a **deploy key with write access** on that one repo (GitHub: Settings → Deploy keys → Allow write access; GitLab: Repository settings → Deploy keys → Grant write permissions). One key per repo: both forges refuse to reuse a key across repos. | The **private** key as a workspace secret |
| `github_app` | A GitHub App with *Repository permissions*: Contents **read & write**, Pull requests **read & write**, Issues **read & write**, Metadata read (nothing under *Account* permissions, no *Administration*). Install it on the repos only (not "all repositories"). Note the App id, the installation id (the number in the installation's URL) and generate a private key (`.pem`). | The `.pem` as a workspace secret, plus the two ids |
| `token` | A **fine-grained** GitHub personal access token limited to the one repo (Contents + Pull requests + Issues read/write), or a GitLab **project** access token (role Developer, scopes `api`/`write_repository`). A **classic** GitHub PAT is refused: it reaches every repo its owner does. | The token as a workspace secret |

A GitHub App is the most useful kind: Arbiter mints a fresh installation token
per dispatch, restricted (`repositories`) to the ticket's repo with only the
permissions a worker needs, and a second, narrower one for `tracker_write`. A
deploy key has no API access, so the tracker token comes from the `tracker_write`
binding (below).

## Registering it

Secrets go in the workspace's encrypted store; the config names them.

```sh
arb workspace secret set TONIC_DEPLOY_KEY --file tonic-deploy-key
arb workspace secret set ARBITER_APP_KEY  --file arbiter-app.private-key.pem
```

(`--file` or stdin keeps the key out of `ps`.) Then put the block in the
workspace `config` (`arb workspace config`, or the dashboard):

```json
"git_credentials": {
  "legacy_operator": false,
  "repos": {
    "tonic":   {"kind": "deploy_key", "key_secret": "TONIC_DEPLOY_KEY"},
    "vstim":   {"kind": "github_app", "app_id": "123456", "installation_id": "7890123",
                "private_key_secret": "ARBITER_APP_KEY"},
    "infra":   {"kind": "token", "token_secret": "INFRA_TOKEN",
                "host": "gitlab.com", "username": "oauth2"},
    "scratch": {"legacy_operator": true}
  }
}
```

`repos` is keyed like `repo_paths` (bare name, or `owner/name`, separators
loose). Optional per-repo keys: `host` (default `github.com`), `username`
(default `x-access-token`; GitLab wants `oauth2`), `remote` (`owner/repo`; default
is parsed from the checkout's `origin`), `api_url` (GitHub Enterprise).
The config is validated on write; a typo is refused rather than read as "unset".

## When Arbiter refuses to dispatch

A spawn that can push (an implementer: first dispatch, revise round, CI fix pass,
conflict pass that is not pushed by the host) is **refused** when its repo has no
scoped credential, with:

> no scoped git credential is configured for repo tonic, and a worker that pushes
> must not run on the operator's ssh-agent or keys. Register a per-repo deploy
> key, GitHub App or repo-scoped token under the workspace's config
> git_credentials.repos.tonic (docs/git-credentials.md), or opt in to the
> operator's credential with git_credentials.legacy_operator: true

This applies to **every** workspace, with or without a `git_credentials` block and
on a guarded or unguarded install: there is no implicit fallback to the operator's
credential. **Upgrading therefore stops dispatching pushing workers** for any
workspace that has not registered a credential or set `legacy_operator: true`;
`arb server doctor` lists them first. Reviewers never need push and are never
refused.

`legacy_operator: true` (workspace-wide, or on one repo, where `false` overrides
the workspace) is the explicit opt-in to the old behaviour: the worker runs as it
always did, with whatever `~/.ssh` and `GH_TOKEN` it can reach. Use it per repo
while you roll credentials out. `arb server doctor` lists every repo that would
be refused (`git_credential_unconfigured`) and every credential naming a secret
the workspace does not have (`git_credential_secret_missing`).

## How it reaches the worker

| Backend | Deploy key | Token |
|---|---|---|
| Unsandboxed Claude / Codex | `0600` file in a per-worker dir under `~/.cache/arbiter/scratch/git-key`, named by `GIT_SSH_COMMAND` (`ssh -F /dev/null -i KEY -o IdentitiesOnly=yes -o IdentityAgent=none`) | `ARB_GIT_TOKEN` in the env, served by a git credential helper (below) |
| bwrap jail (agy) | The same file, bound read-only at its own path over a blanked key dir (a sibling's key is unreachable); with any scoped credential (deploy key, token or App) no `~/.ssh` identity and no `~/.config/gh` login is bound back; the egress `ProxyCommand` is composed onto the command | env, as above |
| podman | A podman **secret** (`podman run --secret NAME,type=mount,target=arb_git_key,uid=…,mode=0400`), created from a `0600` file that is deleted at once, removed with the container, by an owner-exit reaper and at server boot | A podman secret of `type=env` (`ARB_GIT_TOKEN`); the value is never on argv or in `podman inspect` |
| podman on a remote node (bd-akp9ae) | **Never carried**: the run stays on the primary | **GitHub App only**: the installation token minted for the run rides in the run spec's `secrets` and reaches the container through the node's per-run tmpfs file (never argv, `-e` or the node's disk), which is removed when the container exits, is cancelled or is reaped; the token is **revoked** when the run's worker exits. A static `token` is never carried: the run stays on the primary |

Under podman only one kind of run takes a credential into its container at all: a
ReviewGate **fix round** on a repo with a scoped credential, which pushes its own
commits. Every other podman run (the implementer, a resume, a CI fix pass, a conflict
pass) is pushed for by the host (below), so its container, here or on a node, holds no
git credential.

Never an agent socket: `SSH_AUTH_SOCK` is not set (and `IdentityAgent=none`).

For a token the git credential helper (`GIT_CONFIG_PARAMETERS`) first **resets**
every inherited helper (the operator's `gh auth`, keychain, `store`), then answers
only for the repo's own path (`credential.useHttpPath=true`), and ssh remotes of
the host are rewritten to https. A `git push` to any other repo finds no credential
and fails, whatever the token could have reached. Prompts are off
(`GIT_TERMINAL_PROMPT=0`).

## Tracker token

A ticket's `tracker_write` permission projects a token env var (the binding's
`token_env`, default `GH_TOKEN`). With a scoped credential:

* `github_app`: the var carries a second installation token, restricted to the
  repo, with Issues and Pull requests read/write and Contents read.
* `token`: the var carries the repo's own token.
* `deploy_key` (or the binding's `token_secret` alone): the binding's token is
  used, but a **classic PAT is refused** (checked with `GET /user`: a classic PAT
  reports `X-OAuth-Scopes`, a fine-grained or App token does not). Give the
  binding a fine-grained token scoped to the one repo. The check fails closed: if
  GitHub cannot be reached, or answers anything but 2xx, the dispatch is refused.

## The host's push and PR operations (bd-bsmkfu)

A podman run holds no git credential: the **host** pushes the collected branch
after `arb done` (also a fix round's or conflict pass's rewritten branch, and the
review gate's pre-review push) and opens, comments on and merges the PR. With a
scoped entry for the repo the host does all of that with it, not with the
operator's ssh/gh credentials (`Arbiter.Worker.HostCredential`):

* **Push.** `git push` runs with the entry's credential: for a `github_app`, a
  fresh installation token restricted to the repo (Contents, Pull requests and
  Issues read/write, Metadata read), served by the same path-pinned helper; for a
  `deploy_key`, `GIT_SSH_COMMAND` naming the key. The operator's credential
  helpers are reset, `SSH_AUTH_SOCK`, `GIT_ASKPASS` and `SSH_ASKPASS` are unset,
  ssh is told `IdentityAgent=none`/`IdentitiesOnly=yes` (`-F /dev/null`), and
  prompts are off. GitHub shows the App as the pusher.
* **PR open, comment, merge** (the GitHub merger adapter) use the same App
  installation token when the repo's kind is `github_app`, so the App bot is the PR
  author. The merger config's `credentials_ref` is not read for that repo. For a
  `deploy_key` or `token` repo the adapter keeps `credentials_ref` (a deploy key
  has no API access); the GitLab merger is unchanged.
* The installation token is cached in memory for 30 minutes (the Watchdog polls
  every few seconds), then minted again.
* If the scoped credential cannot be built (the secret is gone, the mint fails),
  the push or PR call **fails**; the host never falls back to the operator's
  credential for a repo that has a scoped entry.
* Repos on `legacy_operator`, or with no entry, behave as before.
* **Remote-node runs.** The node runs the agent in a shadow clone; the branch comes
  back to the primary, which pushes it after `arb done` through the same code, so
  those pushes use the scoped env too, and the PR is opened by the App. The node
  itself never needs a credential for an implementer, resume, fix pass or conflict
  pass, which is why they are placed on a node whatever the repo's credential kind
  (bd-akp9ae; bd-21r811 had kept them on the primary). A ReviewGate fix round that
  pushes from its own container is the exception: see "Remote nodes" below.
* Not covered: the Direct merger's local `git push origin <target>`, the GitLab
  merger's branch push, and read-only `git fetch`es, which still run as the
  operator.

The App needs Pull requests **read & write**, Contents **read & write** and Issues
**read & write** for this (the table above already asks for them).

## Remote nodes (bd-akp9ae)

With `worker.placement: prefer_remote` or `remote_only`, a scoped repo's work is placed
on enrolled nodes like any other:

* **Implementer, resume, CI fix pass, conflict pass**: placed on a node whatever the
  repo's credential kind. Nothing credential-shaped is sent to the node; the host
  pushes the branch the run brings back and opens the PR with the repo's credential
  (above), so a GitHub App repo's PR is authored by the App.
* **ReviewGate fix round** on a `github_app` repo: placed on a node, carrying only the
  installation token Arbiter minted on the primary for that round. The token is
  restricted to the one repo (`repositories`) with a worker's push permissions, and
  lasts at most an hour. It travels in the run spec's `secrets`; the node writes it to
  a `0600` file on tmpfs (`$XDG_RUNTIME_DIR/arbiter-node/<run>/secrets.env`), the
  container's wrapper sources it, and the file is removed when the container exits
  (success or failure), when the run is cancelled or quiesced, when the agent stops,
  and by the node's reaper. It is never on argv, in `podman`'s persisted config or on
  the node's disk, and it is redacted from the run's output and its archived
  transcript. When the round's worker exits, however it exits, the primary
  **revokes** the token (`DELETE /installation/token`), so a copy taken off the node
  is dead after the run.
* **ReviewGate fix round** on a `deploy_key` or `token` repo: stays on the primary
  (placement reason `scoped_git_credential`); a spawn that tried it would be refused
  (`git_credential_unsupported`). Those are long-lived secrets.
* **Never sent to a node**: the App's private key (it only signs the mint, on the
  primary), a deploy key, a static token. If the operator also exposed one of them to
  workers as a `worker_env` var, that var is held back from a remote run (the
  primary logs its name, never its value).

To check a node after a run: `ls "$XDG_RUNTIME_DIR/arbiter-node"` on the node holds a
directory only while a run is live, and `podman secret ls` lists no Arbiter git secret
(remote runs use the tmpfs file, not podman secrets).

## Limits, said plainly

* **Unsandboxed Claude and Codex run as the operator's uid.** Scoping stops
  Arbiter handing them the operator's credential; it cannot stop a same-uid
  process from reading `~/.ssh` itself (see `docs/worker-security.md`, "Residual
  risk: same UID"). The bwrap jail (agy) and podman remove that reach; the deploy
  key's file is `0600` in a `0700` directory but is readable by any same-uid
  process outside a jail.
* A token (App installation tokens last an hour) is in the worker's env for the
  run. A run longer than the token's life must be re-dispatched.
* On a remote node only a GitHub App's short-lived token is ever carried (see
  "Remote nodes" above); a fix round on a deploy-key or static-token repo stays on the
  primary.
* A fix round on a node can read its own token (it is in the container's
  environment). A copy the agent itself writes into its transcript or work tree stays
  on the node with the run's directory until the node's reaper takes it (24 h). By
  then it is dead: the token is revoked when the round's worker exits, and expires
  within the hour.
* The scope of a `token` is as good as the token you created: Arbiter checks it is
  not a classic PAT, not that you restricted it to one repo.
* Enforcement of "a push to a different repo fails" is two layers: the forge (a
  deploy key / App token / fine-grained token reaches one repo) and, for tokens,
  the helper above. The forge-side layer is the one you configure; Arbiter's tests
  cover the helper and the mint request (`repositories`, permissions) but cannot
  exercise GitHub itself.
