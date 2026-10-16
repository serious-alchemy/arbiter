defmodule Arbiter.Worker.HostCredential do
  @moduledoc """
  The credential the *host* uses for a repo with a scoped `git_credentials` entry
  (`Arbiter.Worker.GitCredential`, bd-bsmkfu).

  A podman run holds no git credential (`GitCredential.plan/3` is `:not_needed`
  under `host_pushes?`): the host pushes the collected branch after `arb done`
  and opens, comments on and merges the PR. Without this the host does all of it
  on the operator's own ssh/gh credentials, whatever the repo is configured with.
  With it, a repo whose entry is a `deploy_key`, `token` or `github_app` is pushed
  and opened with that credential, so GitHub shows the App as the pusher and the
  PR author. A repo on `legacy_operator`, or with no entry, is unchanged
  (`{:ok, nil}`).

  This reuses `GitCredential.materialize/3` (the one mint path; `host?: true`
  asks for the pull-request and merge permissions as well as `contents: write`)
  and `GitCredential.stage/3`. The installation token is memoized for a while
  (`HostCredential.Cache`) because the Watchdog re-seeds the adapter every poll.

  ## The push env

  The `:env` of a credential is for `Worktree.push/2`'s `:env` (a `{name, nil}` pair
  unsets). It never inherits the operator's helpers or identities:

    * `credential.helper` is reset (`GIT_CONFIG_PARAMETERS`), and for a token the
      helper that answers only for the repo's own path is installed;
    * `SSH_AUTH_SOCK`, `GIT_ASKPASS` and `SSH_ASKPASS` are unset, and
      `GIT_TERMINAL_PROMPT=0`;
    * `GIT_SSH_COMMAND` offers the staged key and nothing else
      (`IdentitiesOnly`, `IdentityAgent=none`, `-F /dev/null`), or, for a token,
      offers no identity at all (an ssh remote is rewritten to https anyway).

  A scoped plan that cannot be materialized (the secret is missing, the mint
  fails) is an `{:error, _}`: the push is refused, never run on the operator's
  credential.
  """

  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.GitCredential.Material
  alias Arbiter.Worker.HostCredential.Cache

  # How long a host-minted GitLab project token lives: the push follows `for_repo/3`
  # at once, and the token is revoked this long after (or when the owner exits).
  @push_window_ms 10 * 60_000

  @type t :: %{
          material: Material.t(),
          env: [{String.t(), String.t() | nil}],
          redact: [String.t()]
        }

  @doc """
  The host credential for `repo` in `workspace`: `{:ok, nil}` when the repo has no
  scoped entry (the operator's credential applies, as before), `{:ok, credential}`
  when it has one, `{:error, reason}` when it has one that cannot be used
  (`format_error/1`).

  Options: `:worktree_path` (whose `origin` pins a token to its repo), `:remote`
  (`owner/repo`; the entry's own `remote` wins), `:owner` (the pid a staged deploy
  key lives as long as; default `self()`), `:root` (where a key is staged),
  `:req_options` (merged into the mint request), `:revoke_after_ms` (a
  `gitlab_project_token`'s revoke deadline, default ten minutes).
  """
  @spec for_repo(map() | nil, String.t() | nil, keyword()) ::
          {:ok, t() | nil} | {:error, term()}
  def for_repo(workspace, repo, opts \\ []) do
    case GitCredential.plan(workspace, repo) do
      {:ok, %GitCredential{mode: :scoped} = plan} -> scoped(plan, workspace, opts)
      _ -> {:ok, nil}
    end
  end

  @doc "`for_repo/3`'s env for `Worktree.push/2`: `[]` for the operator's credential."
  @spec push_env({:ok, t() | nil} | t() | nil) :: [{String.t(), String.t() | nil}]
  def push_env({:ok, credential}), do: push_env(credential)
  def push_env(%{env: env}), do: env
  def push_env(_), do: []

  @doc "The token for the forge API (PR open, comment, merge), or `nil` (a deploy key has none)."
  @spec token(t() | nil) :: String.t() | nil
  def token(%{material: %Material{token: token}}) when is_binary(token), do: token
  def token(_), do: nil

  @doc """
  The repo's `github_app` token for the GitHub merger adapter
  (`Arbiter.Mergers.Github.Config`): `{:ok, nil}` when the repo is not a
  `github_app` repo (the adapter keeps its configured credential), `{:ok, token}`,
  or `{:error, reason}`. Request options for the mint come from
  `config :arbiter, :host_credential_req_options` (tests stub with `plug:`).
  """
  @spec forge_token(map() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def forge_token(workspace, repo, opts \\ []) do
    case GitCredential.plan(workspace, repo) do
      {:ok, %GitCredential{mode: :scoped, entry: %{kind: :github_app}} = plan} ->
        opts =
          opts
          |> Keyword.put_new(:req_options, req_options())
          |> Keyword.put_new_lazy(:worktree_path, fn -> checkout_path(workspace, repo) end)

        with {:ok, material} <- materialize(plan, workspace, opts) do
          {:ok, material.token}
        end

      _ ->
        {:ok, nil}
    end
  end

  @doc "Human text for an `{:error, reason}` from this module."
  @spec format_error(term()) :: String.t()
  def format_error(reason), do: GitCredential.format_error(reason)

  # The checkout `repo_paths` registers for `repo`: its `origin` names the repo a
  # token is minted for when neither the caller nor the entry says.
  defp checkout_path(%{config: %{"repo_paths" => %{} = paths}}, repo) when is_binary(repo),
    do: paths |> RepoConfig.find_entry(repo) |> RepoConfig.repo_path_from_config()

  defp checkout_path(_workspace, _repo), do: nil

  defp req_options, do: Application.get_env(:arbiter, :host_credential_req_options, [])

  defp scoped(plan, workspace, opts) do
    with {:ok, material} <- materialize(plan, workspace, opts),
         {:ok, staged} <- stage(material, opts) do
      {:ok,
       %{
         material: material,
         env: env(material, staged.env),
         redact: GitCredential.redact_values(material)
       }}
    end
  end

  defp materialize(%GitCredential{entry: entry} = plan, workspace, opts) do
    remote = Keyword.get(opts, :remote) || GitCredential.origin_remote(opts[:worktree_path])

    materialize_opts =
      [remote: remote, host?: true] ++ Keyword.take(opts, [:req_options])

    compute = fn -> GitCredential.materialize(plan, workspace, materialize_opts) end

    case entry.kind do
      :github_app ->
        Cache.fetch(cache_key(entry, remote), compute)

      # Minted for this push, not memoized: it is revoked once the push window
      # closes (or the owner exits), so a cached token would go stale under a caller.
      :gitlab_project_token ->
        with {:ok, material} <- compute.() do
          revoke_opts =
            Keyword.take(opts, [:req_options]) ++
              [max_ms: Keyword.get(opts, :revoke_after_ms, @push_window_ms)]

          :ok =
            GitCredential.revoke_when_down(
              Keyword.get(opts, :owner, self()),
              material,
              revoke_opts
            )

          {:ok, material}
        end

      _ ->
        compute.()
    end
  end

  # What a mint depends on: the App, its installation, the repo, and the key.
  defp cache_key(entry, remote),
    do: {entry.app_id, entry.installation_id, entry.remote || remote, entry.private_key_secret}

  defp stage(material, opts) do
    owner = Keyword.get(opts, :owner, self())
    GitCredential.stage(material, owner, Keyword.take(opts, [:root]))
  end

  @unset ~w(SSH_AUTH_SOCK SSH_ASKPASS GIT_ASKPASS GIT_CONFIG_COUNT)
  @reset_helpers "'credential.helper='"

  # The material's own env wins over the baseline; each name appears once.
  defp env(%Material{} = material, delivered) do
    baseline =
      Enum.map(@unset, &{&1, nil}) ++
        [{"GIT_TERMINAL_PROMPT", "0"}] ++ identity_env(material) ++ helper_env(material)

    Enum.reduce(delivered, baseline, fn {name, value}, acc ->
      List.keystore(acc, name, 0, {name, value})
    end)
  end

  # A token remote is https (ssh is rewritten onto it), so ssh must offer no
  # identity; a deploy key's own `GIT_SSH_COMMAND` comes with the staged env.
  defp identity_env(%Material{kind: :deploy_key}), do: []

  defp identity_env(%Material{}),
    do: [{"GIT_SSH_COMMAND", GitCredential.ssh_command("/dev/null")}]

  # A deploy key brings no helper of its own; a push over https must still not
  # fall back to the operator's.
  defp helper_env(%Material{kind: :deploy_key}),
    do: [{"GIT_CONFIG_PARAMETERS", @reset_helpers}]

  defp helper_env(%Material{}), do: []
end
