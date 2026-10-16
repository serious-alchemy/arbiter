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
| `gitlab_project_token` | A **parent** GitLab personal access token (scope `api`) of a Maintainer or Owner of the one project, ideally a dedicated service-account user. Arbiter mints the token a worker holds from it, per run (see "GitLab" below). | The parent token as a workspace secret |
| `token` | A **fine-grained** GitHub personal access token limited to the one repo (Contents + Pull requests + Issues read/write), or a GitLab **project** access token (role Developer, scopes `api`/`write_repository`). A **classic** GitHub PAT is refused: it reaches every repo its owner does. | The token as a workspace secret |

A GitHub App is the most useful kind on GitHub: Arbiter mints a fresh installation token
per dispatch, restricted (`repositories`) to the ticket's repo with only the
permissions a worker needs, and a second, narrower one for `tracker_write`. A
deploy key has no API access, so the tracker token comes from the `tracker_write`
binding (below). `gitlab_project_token` is the GitLab counterpart.

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
    "device":  {"kind": "gitlab_project_token", "parent_token_secret": "GITLAB_PARENT_PAT"},
    "scratch": {"legacy_operator": true}
  }
}
```

`repos` is keyed like `repo_paths` (bare name, or `owner/name`, separators
loose). Optional per-repo keys: `host` (default `github.com`; `gitlab.com` for
`gitlab_project_token`), `username` (default `x-access-token`; `oauth2` for
`gitlab_project_token`; GitLab wants `oauth2`), `remote` (`owner/repo`, or
`group/subgroup/project` on GitLab; default is parsed from the checkout's `origin`),
`api_url` (GitHub Enterprise; for `gitlab_project_token` the REST base of a self-managed
instance, `https://git.example.com/api/v4`, default `https://<host>/api/v4`),
`expires_in_days` (`gitlab_project_token` only: 1 to 7, default 2).
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
| podman on a remote node (bd-akp9ae) | **Never carried**: the run stays on the primary | **GitHub App and `gitlab_project_token` only**: the installation (or project) token minted for the run rides in the run spec's `secrets` and reaches the container through the node's per-run tmpfs file (never argv, `-e` or the node's disk), which is removed when the container exits, is cancelled or is reaped; the token is **revoked** when the run's worker exits. A static `token` is never carried: the run stays on the primary |

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

## GitLab: `gitlab_project_token` (bd-3llb3y)

GitLab has no installation token to mint from a key, so Arbiter builds the same thing
from GitLab's **project access tokens**:

* **Mint.** At each spawn the primary calls `POST /projects/:id/access_tokens` with the
  parent credential. The parent must be a personal access token: GitLab refuses a project
  access token on that endpoint, and a project access token cannot create other tokens.
  The new token is for **that one project** (the path from `remote`, else the checkout's
  `origin`, URL-encoded; nested groups work), role **Developer**, scopes **`read_api` +
  `write_repository`**, named `arbiter-run-<n>`, expiring at midnight UTC `expires_in_days`
  from now (default 2: an expiry is a date, so one day could be minutes).
* **What the token can do.** `write_repository` is git push and pull over https, to the
  branches the Developer role may push to: not a protected branch whose push rule is
  Maintainers (GitLab's default for the default branch). `read_api` reads the API
  (pipelines, jobs, job logs, artifacts, merge requests and their notes). It has no API
  write access, so it **cannot approve or merge** a merge request, open or edit one, or
  change settings (that needs `api`). It cannot reach another project: a project access
  token is bound to its project. Arbiter checks the reply, and a token granted more scopes
  or a higher role than asked for is revoked at once and the spawn refused.
* **Delivery.** As the `token` kind does locally: `ARB_GIT_TOKEN` and the path-pinned git
  credential helper, with `git@<host>:` and `ssh://git@<host>/` remotes rewritten to https
  (so a worker whose `origin` is ssh pushes over https with the run's token). The same token
  is `GITLAB_TOKEN` (so `glab` works, or `curl -H "PRIVATE-TOKEN: $GITLAB_TOKEN" ...`), with
  no operator login, and `GITLAB_HOST` names the instance. Under podman both are
  `--secret`s of type env; on a node both are entries of the run spec's `secrets`, in the
  per-run tmpfs file. Because the token is also the worker's API access, this is the one
  scoped kind that every podman run holds in its container (implementer, resume, CI fix pass,
  conflict pass, fix round), not only a fix round. The host still pushes the branch after
  `arb done`, with a token it mints for that push and revokes ten minutes later (or when
  its caller exits).
* **Revoke.** `DELETE /projects/:id/access_tokens/:token_id`, authenticated by the parent,
  when the run's worker exits however it exits. This is armed when the token is minted, so it
  covers local, podman and node runs alike, and a node found down ends the run's worker.
  A failed revoke is logged (never the token); the token then dies at its `expires_at`.
* **The parent never leaves the primary.** It is read only to mint and to revoke. No env,
  podman secret or run-spec value is built from it, `withheld_values/1` drops an env var that
  carries it from a remote run, the output scrubber masks it, and `inspect/1` of the
  credential hides it. Its reach is whatever its owner can do: use a **dedicated
  service-account user** that is Maintainer on only the projects Arbiter works on.
* **Placement.** The kind is remote-carryable (`Placement.remote_git_credential_kinds/0`):
  `prefer_remote` places the run on a node and `remote_only` does not hold it.

Mechanisms considered:

| Mechanism | Verdict |
|---|---|
| **Project access token**, minted and revoked through the API from a primary-only parent PAT | **Chosen.** Bound to one project, scopes and role set per token, revocable, serves both push and API. |
| CI job token (`CI_JOB_TOKEN`) | Rejected: exists only inside a CI job, so Arbiter cannot mint one for a worker, and its rights are narrow and set by the instance. |
| OAuth application with scoped tokens | Rejected: a token belongs to a *user*, so it reaches every project that user can; it cannot be limited to one project, and it needs an app registration and an authorization flow per run. |

GitLab tiers (docs.gitlab.com, read 2026-10-16): project access tokens need **Premium or
Ultimate on GitLab.com** (a trial is limited to one token) and are available at **any tier on
self-managed and Dedicated**. Creating one needs Maintainer or Owner on the project, and its
role cannot exceed its creator's. An expiry is mandatory (up to 365 days; an administrator may
lower the maximum). On GitLab.com Free, use `deploy_key` (which stays on the primary) or
`legacy_operator`.

Protect your branches. A Developer token can merge into a protected branch whose *Allowed to
merge* includes Developers, and can set merge-when-pipeline-succeeds with a push option on a
branch it creates. Keep the default branch's *Allowed to push* and *Allowed to merge* on
Maintainers (GitLab's default), and the parent's owner no higher than needed.

### Moving a GitLab workspace off `legacy_operator`

1. On each project, create (or reuse) a service-account user, add it as **Maintainer**, and
   create a personal access token for it with scope **`api`** and an expiry you will renew.
   When it lapses, minting fails and dispatches are refused (not run on the operator's
   credential).
2. `arb workspace secret set GITLAB_PARENT_PAT --file parent-pat`.
3. In the workspace `config`, give each repo
   `{"kind": "gitlab_project_token", "parent_token_secret": "GITLAB_PARENT_PAT"}` (add `host`
   or `api_url` for self-managed, and `remote` if the checkout's `origin` is not the GitLab
   path). A repo's own entry wins over the workspace's `legacy_operator`, so move one repo at
   a time, leave the workspace flag `true` until the last is done, then set it `false`.
4. `arb server doctor` should list no `git_credential_secret_missing` for the repo. Dispatch a
   small ticket and check: the branch is pushed, the run could read its pipeline (the
   `PRIVATE-TOKEN: $GITLAB_TOKEN` call above answers 200), and *Settings → Access tokens* on the
   project shows an `arbiter-run-*` token while the run lives and none after.
5. Then set `worker.placement: prefer_remote`.

What changes: a worker no longer pushes with the operator's ssh key, so it reaches its own
project only, and it no longer sees the operator's `glab` login (the bwrap jail now masks
`~/.config/glab-cli` as it does `~/.config/gh`; `worker_jail_unmask` is the escape hatch). Not
changed: the GitLab merger keeps its `credentials_ref` for MR calls, and the Direct and GitLab
mergers' own branch pushes still run as the operator.

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
  repo's credential kind. Nothing credential-shaped is sent to the node (a
  `gitlab_project_token` repo's run-scoped token, below, is the exception); the host
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
* **`gitlab_project_token`** (bd-3llb3y): every run kind's container holds the run's token,
  so all of them carry it to a node the same way: in the run spec's `secrets` (the tmpfs file,
  removed with the container), revoked when the worker exits or its node is found down. Only
  the minted token goes; the parent credential never does.
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
* On a remote node only a GitHub App's or a GitLab project token (both minted per run; see
  "Remote nodes" above) is ever carried; a fix round on a deploy-key or static-token repo
  stays on the primary.
* A GitLab project token lives until its `expires_at` date (default two days) when Arbiter
  cannot revoke it: the revoke is armed in the server process, so a server that dies mid-run
  leaves the token to expire, as does a parent PAT that has been revoked or has lapsed. Set
  `expires_in_days: 1` for the shortest life GitLab allows.
* Arbiter's tests stub the GitLab API (`Req.Test`). They cover the mint request (project,
  scopes, role, expiry), the refusal of an over-granted token, the revokes, delivery and
  placement, not GitLab itself. The first run on a real project shows that the parent's role
  may mint a Developer token and that the push and the API read work.
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
