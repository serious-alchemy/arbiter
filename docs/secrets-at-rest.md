# Secrets at rest: keeping secret values off the host's disk

By default every secret arbiter needs ends up as plaintext in the systemd
`EnvironmentFile` (`~/.arbiter/arbiter.env`), and a host secret scanner flags that
file and every copy of it. Arbiter can instead hold **pointers** to a secret
manager and fetch the value into memory when it needs it.

## Reference forms

| Form | Source |
|---|---|
| `aws-sm:<secret-id>[#json-key]` | AWS Secrets Manager `GetSecretValue`. `<secret-id>` is a name or ARN. With `#json-key` the secret string is parsed as a JSON object and that string field is returned. |
| `aws-ssm:<parameter-name>[#json-key]` | SSM Parameter Store, decrypted (`SecureString`). |
| `file:<path>` | A file's contents, trailing whitespace trimmed: systemd `LoadCredential=`, a tmpfs, a Kubernetes secret mount. No `#json-key`. |

AWS authentication is the ambient credential chain: `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY`, ECS/EKS container credentials, `~/.aws/credentials`
(`AWS_PROFILE`), then the EC2 instance role (IMDSv2). The region comes from the
ARN when the id is one, otherwise `AWS_REGION` / `AWS_DEFAULT_REGION` / IMDS.
`AWS_ENDPOINT_URL_SECRETS_MANAGER`, `AWS_ENDPOINT_URL_SSM` and `AWS_ENDPOINT_URL`
override the endpoint (VPC endpoints, LocalStack). The instance role needs
`secretsmanager:GetSecretValue` / `ssm:GetParameter` (+ `kms:Decrypt`) on the
referenced secrets only.

Values are resolved lazily, cached **in memory only** for
`ARBITER_SECRET_CACHE_TTL` seconds (default 300; `0` disables the cache), never
written to disk or logged, and added to the redaction set
(`Arbiter.Redaction`). If a refresh fails, the last value keeps being served and a
warning naming the pointer (never a value) is logged.

## 1. `credentials_ref` (trackers, mergers, agents)

Anywhere `env:` / `secret:` work, the forms above work:

Set the workspace's `credentials_ref` (tracker, merger or agent config) to e.g.
`aws-sm:prod/arbiter#github_token`. `workspace_config_get` returns the pointer,
never the value.

## 2. Boot-time secrets

`ARBITER_CLOAK_KEY` (and `ARBITER_CLOAK_KEY_OLD`), `SECRET_KEY_BASE` cannot live in
the workspace store (the first decrypts it; the second is needed to boot). Give
each as a pointer instead of a value:

```
# ~/.arbiter/arbiter.env — no secret values
ARBITER_CLOAK_KEY_REF=aws-sm:prod/arbiter#cloak_key
SECRET_KEY_BASE_REF=aws-sm:prod/arbiter#secret_key_base
AWS_REGION=eu-west-1
```

* A `<NAME>_REF` **wins** over an inline `<NAME>`; remove the inline value once
  the pointer works (`arb doctor` warns while both exist).
* A pointer that cannot be resolved **fails the boot** (`runtime.exs` / the Vault
  raise, naming the variable and the pointer), the same as a missing key.
* `ARBITER_CLOAK_KEY_GENERATION` is a number, not a secret, and stays inline.
  Key rotation (`docs/cloak-key-rotation.md`) works unchanged:
  `ARBITER_CLOAK_KEY_OLD_REF` points at the retired key.
* `bin/arbiter eval` (migrations, the deploy backup) runs `runtime.exs` too, so
  it needs the same ambient AWS access as the service.

## 3. `GITHUB_TOKEN`

The merger/tracker default `credentials_ref: "env:GITHUB_TOKEN"` honours
`GITHUB_TOKEN_REF`, as do the server's own direct reads (release update check,
self-deploy, the worker CLI fetcher, the `Arbiter.GitHub` fallback). In general
`env:NAME` resolves `NAME_REF` first. With `secret:` refs on the merger/tracker
and `GITHUB_TOKEN_REF` (or no token) in the env file, `GITHUB_TOKEN` can leave the
environment entirely.

The `arb` CLI's own `GITHUB_TOKEN` reads (`arb self-update`, `arb server deploy`)
are optional — they only authenticate the public Releases API request to raise
the rate limit — and read the token from the invoking shell, not from the env
file. They do not resolve `*_REF`.

## 4. Deploy snapshots

`arb server deploy` never copies `arbiter.env`. Each database snapshot gets a
sidecar `<snapshot>.env-fingerprint.json` listing every env key with the first 8
hex characters of the SHA-256 of its value (for a `*_REF` key, of the pointer),
enough to verify a redeploy did not change a value, not to recover it.

## Checking the posture

* `arb install-service` prints `at rest: inline: …; references: …` for the env
  file it just wrote (and `secrets_at_rest` in `--json`). It forwards `*_REF`
  pointers from the installing shell and never writes the inline value of a
  secret whose `*_REF` is set.
* `arb doctor` has a `secrets at rest` check (security posture): `warn` while
  `ARBITER_CLOAK_KEY` / `SECRET_KEY_BASE` is inline, while an inline value is
  shadowed by its pointer, or when a pointer has an unrecognised scheme.
* Old copies of the env file (backups, snapshots, logs from older versions)
  are outside what arbiter manages; rotate the secrets they hold.
