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

This applies on a **guarded install** (guardrail subject rules are configured,
G11) and to any workspace that has a `git_credentials` block. An install with
neither is unchanged (`mode: :unenforced`): upgrading does not stop dispatching.
Reviewers never need push and are never refused.

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
| bwrap jail (agy) | The same file, bound read-only at its own path over a blanked key dir (a sibling's key is unreachable); `~/.ssh` identities are **not** bound back; the egress `ProxyCommand` is composed onto the command | env, as above |
| podman | A podman **secret** (`podman run --secret NAME,type=mount,target=arb_git_key,uid=…,mode=0400`), created from a `0600` file that is deleted at once, removed with the container, by an owner-exit reaper and at server boot | A podman secret of `type=env` (`ARB_GIT_TOKEN`); the value is never on argv or in `podman inspect` |

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
  binding a fine-grained token scoped to the one repo.

## Limits, said plainly

* **Unsandboxed Claude and Codex run as the operator's uid.** Scoping stops
  Arbiter handing them the operator's credential; it cannot stop a same-uid
  process from reading `~/.ssh` itself (see `docs/worker-security.md`, "Residual
  risk: same UID"). The bwrap jail (agy) and podman remove that reach; the deploy
  key's file is `0600` in a `0700` directory but is readable by any same-uid
  process outside a jail.
* A token (App installation tokens last an hour) is in the worker's env for the
  run. A run longer than the token's life must be re-dispatched.
* A run placed on a remote node is refused when it needs a scoped credential
  (no podman secret to carry it there yet).
* The scope of a `token` is as good as the token you created: Arbiter checks it is
  not a classic PAT, not that you restricted it to one repo.
* Enforcement of "a push to a different repo fails" is two layers: the forge (a
  deploy key / App token / fine-grained token reaches one repo) and, for tokens,
  the helper above. The forge-side layer is the one you configure; Arbiter's tests
  cover the helper and the mint request (`repositories`, permissions) but cannot
  exercise GitHub itself.
