defmodule Arbiter.Worker.Jail.Hide do
  @moduledoc """
  The read paths the agy jail hides from a jailed worker (bd-3q2djr, G3 of
  `docs/design/guardrail-profiles.md` §9, §2.3–2.5).

  `--ro-bind / /` makes the whole filesystem readable, and the worker runs as
  the operator's uid, so it can read every credential the operator can. This
  is the denylist (the design's proposal; the allowlist alternative,
  `--tmpfs $HOME` plus explicit mounts, would break `mise`, `mix`, `gh` and
  whatever toolchain a repo brings, so it was not taken). `paths/1` resolves
  it against the host as `%{dirs, files, keep}`, which `Arbiter.Worker.Jail`
  turns into `--tmpfs <dir>`, `--ro-bind-try <keep> <keep>` and
  `--ro-bind /dev/null <file>`, in that order, before any bind the worker is
  meant to see (its worktree, HOME, git dirs, egress sockets), so those come
  back on top of a masked parent.

  ## Path classes

    * **Credential dirs** under the operator's home: `~/.claude`, `~/.codex`,
      `~/.grok` (the canonical grok login, whose refresh token only
      `Arbiter.Grok.CredentialBroker` may hold), `~/.gemini` (the operator's own agy state; the worker has its isolated
      HOME), `~/.config/gh`, `~/.config/gcloud`, `~/.ssh`, `~/.aws`,
      `~/.kube`, `~/.docker`; and the files `~/.netrc`, `~/.pgpass`,
      `~/.git-credentials`. `~/.grok` also holds the grok binary and its
      bundled assets, so `~/.grok/bin`, `downloads` and `bundled` are bound
      back read-only (`grok_keep/1`); `auth.json` and the rest stay masked.
    * **The install**: the data dir (`~/.arbiter`: the DB and its WAL, the
      account configs, `arbiter.env`, the release cookie, releases), the
      configured DB path and its `-wal` / `-shm` / `-journal` sidecars when it
      lives elsewhere, and the accounts and sessions roots.
    * **Other workers**: the durable output-log root, the worktree root (every
      other worker's worktree; the own one is bound back), the agy HOME root
      (other workers' `mcp_config.json` scope tokens; the own HOME is bound
      back) and the Claude worker config dir (`.credentials.json`).
    * **Other workspaces' repos**: every `repo_paths` entry of every
      workspace except the repo the worker's own worktree belongs to.

  Only paths that exist are listed (bwrap cannot create a mount point under
  the read-only root, and an absent path is no vector). A symlinked path is
  masked at its real location: a mask on the link would leave the target
  readable. The agy HOME symlinks `.ssh`, `.arbiter` and `.config` back to
  the operator's, so masking the real directories covers the passthrough too.

  ## What stays visible on purpose

  `~/.ssh` is blanked, then `known_hosts`, `config`, `config.d` and the
  default identity files (`id_rsa`, `id_ecdsa`, `id_ed25519`, `id_dsa`, and
  the `.pub` of each) are bound back read-only: that is what `git push` over
  the egress `ProxyCommand` needs (`docs/worker-security.md`: git over ssh uses
  a key file readable in `~/.ssh`). Any other key, such as a deploy key a
  `Host` block names, is hidden; the per-binding agent in G14 is the way to
  hand one out.

  `~/.config/gh` is blanked too, then `hosts.yml` and `config.yml` are bound
  back when `hosts.yml` holds no `oauth_token` (a keyring-backed login: the
  file names the account but carries no secret, and the token comes through
  the keyring bus), so `gh pr view` / `gh pr diff` keep working for agy
  reviews. A `hosts.yml` with a plaintext token keeps the whole dir hidden;
  `gh` then needs a `GH_TOKEN`/`GITHUB_TOKEN` in the workspace's `worker_env`.

  `config :arbiter, :worker_jail_unmask, [path]` is the operator's escape
  hatch: an entry equal to a masked path drops that mask; an entry beneath
  one is bound back read-only (`~` expands).
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.CredentialPaths

  require Logger

  @type t :: %{dirs: [String.t()], files: [String.t()], keep: [String.t()]}

  @credential_dirs CredentialPaths.dirs()
  @credential_files CredentialPaths.files()

  @identities ~w(id_rsa id_ecdsa id_ed25519 id_dsa id_ecdsa_sk id_ed25519_sk)
  @ssh_keep ~w(known_hosts config config.d) ++
              @identities ++ Enum.map(@identities, &(&1 <> ".pub"))

  @sidecars ["-wal", "-shm", "-journal"]

  @doc """
  Resolve the hide set against this host.

  Options, all defaulting to the live configuration (the overrides are for
  tests): `:operator_home`, `:data_dir`, `:database`, `:accounts_root`,
  `:worktree_root`, `:log_root`, `:sessions_root`, `:agy_home_root`,
  `:grok_home_root`, `:claude_config_dir`, `:repos` (every workspace repo path), `:own_repo`
  (the repo the worker's worktree belongs to, never hidden) and `:unmask`. `:scoped_git`
  (G16: the worker has a repo-scoped git credential, so no operator identity
  file — ssh key or gh login — is bound back).
  """
  @spec paths(keyword()) :: t()
  def paths(opts \\ []) do
    home = opt(opts, :operator_home, &operator_home/0)
    unmask = unmask(opts, home)

    candidate_dirs =
      Enum.map(@credential_dirs, &join(home, &1)) ++
        Enum.map(install_dirs(opts), &expand/1) ++
        Enum.map(other_worker_dirs(opts), &expand/1) ++ repo_dirs(opts)

    candidate_files =
      Enum.map(@credential_files, &join(home, &1)) ++ database_files(opts)

    dirs =
      candidate_dirs
      |> existing(&File.dir?/1)
      |> reject_unsafe(home)
      |> Enum.reject(&(&1 in unmask))
      |> Enum.uniq()
      |> drop_nested()

    files =
      candidate_files
      |> existing(&File.regular?/1)
      |> Enum.reject(&(&1 in unmask or under_any?(&1, dirs)))
      |> Enum.uniq()

    scoped? = Keyword.get(opts, :scoped_git, false)

    keep =
      (ssh_keep(home, scoped?) ++
         gh_keep(home, scoped?) ++ grok_keep(home) ++ unmask)
      |> existing(&File.exists?/1)
      |> Enum.filter(&under_any?(&1, dirs))
      |> Enum.uniq()

    %{dirs: dirs, files: files, keep: keep}
  end

  @doc """
  Every path in `hide` that exists on the host and holds something a worker
  could read: a masked file's own path (when non-empty), and one entry of each
  masked directory (when it has any). The probe asserts none of them is
  reachable inside the jail.
  """
  @spec probe_targets(t()) :: [{:file | :dir, String.t()}]
  def probe_targets(%{dirs: dirs, files: files, keep: keep}) do
    dir_targets =
      Enum.flat_map(dirs, fn dir ->
        with {:ok, entries} <- File.ls(dir),
             entry when is_binary(entry) <-
               Enum.find(entries, &(Path.join(dir, &1) not in keep)) do
          [{:dir, Path.join(dir, entry)}]
        else
          _ -> []
        end
      end)

    file_targets =
      for f <- files, match?({:ok, %{size: s}} when s > 0, File.stat(f)), do: {:file, f}

    file_targets ++ dir_targets
  end

  @doc "Every workspace's `repo_paths` entries (`[]` when the lookup fails)."
  @spec workspace_repos() :: [String.t()]
  def workspace_repos do
    Workspace
    |> Ash.read!()
    |> Enum.flat_map(fn
      %{config: %{"repo_paths" => paths}} when is_map(paths) ->
        paths |> Map.values() |> Enum.map(&RepoConfig.repo_path_from_config/1)

      _ ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    e ->
      Logger.warning(
        "Arbiter.Worker.Jail.Hide: could not list workspace repos " <>
          "(#{Exception.message(e)}); other workspaces' repos are not hidden"
      )

      []
  end

  # ---- candidates ----------------------------------------------------------

  defp install_dirs(opts) do
    [
      opt(opts, :data_dir, &data_dir/0),
      opt(opts, :accounts_root, &Paths.accounts_root/0),
      opt(opts, :sessions_root, &Paths.sessions_root/0)
    ]
  end

  defp other_worker_dirs(opts) do
    [
      opt(opts, :worktree_root, &Paths.worktree_root/0),
      opt(opts, :log_root, &Paths.output_log_root/0),
      opt(opts, :agy_home_root, &Arbiter.Agents.Gemini.ConfigDir.home_root/0),
      opt(opts, :grok_home_root, &Arbiter.Agents.Grok.ConfigDir.home_root/0),
      opt(opts, :claude_config_dir, &Arbiter.Agents.Claude.ConfigDir.path/0)
    ]
  end

  defp repo_dirs(opts) do
    own = opts |> Keyword.get(:own_repo) |> real()
    repos = Keyword.get_lazy(opts, :repos, &workspace_repos/0)

    repos |> Enum.map(&expand/1) |> Enum.reject(&(real(&1) == own and own != nil))
  end

  defp database_files(opts) do
    case opt(opts, :database, &database/0) do
      db when is_binary(db) and db != "" and db != ":memory:" ->
        db = expand(db)
        [db | Enum.map(@sidecars, &(db <> &1))]

      _ ->
        []
    end
  end

  # The grok binary is `~/.grok/bin/grok` -> `../downloads/grok-linux-*`, and it
  # reads its `bundled/` agents and skills; a jailed grok worker needs all three.
  # None holds a credential (the login is `auth.json`, which stays masked).
  @grok_keep ~w(bin downloads bundled)
  defp grok_keep(nil), do: []
  defp grok_keep(home), do: Enum.map(@grok_keep, &Path.join([home, ".grok", &1]))

  defp ssh_keep(nil, _scoped?), do: []

  defp ssh_keep(home, scoped?) do
    names =
      if scoped?,
        do: @ssh_keep -- (@identities ++ Enum.map(@identities, &(&1 <> ".pub"))),
        else: @ssh_keep

    Enum.map(names, &Path.join([home, ".ssh", &1]))
  end

  # A keyring-backed gh login keeps no secret in `hosts.yml` (the token sits in
  # the Secret Service, which the jail reaches over the filtered dbus proxy), so
  # `hosts.yml` and `config.yml` come back and `gh` still knows the account. A
  # `hosts.yml` holding a plaintext `oauth_token` (or one we cannot read) keeps
  # the whole dir hidden.
  #
  # G16: under a scoped git credential the operator's gh account is not bound
  # back at all: without `hosts.yml`, `gh` does not know the account, so it cannot
  # look up the operator's full-scope keyring token and write to another repo.
  # The scoped token (`GH_TOKEN`) is the only tracker identity.
  defp gh_keep(nil, _scoped?), do: []
  defp gh_keep(_home, true), do: []

  defp gh_keep(home, false) do
    hosts = Path.join([home, ".config", "gh", "hosts.yml"])

    case File.read(hosts) do
      {:ok, body} ->
        if String.contains?(body, "oauth_token"),
          do: [],
          else: [hosts, Path.join([home, ".config", "gh", "config.yml"])]

      {:error, _} ->
        []
    end
  end

  # ---- configuration -------------------------------------------------------

  defp operator_home do
    case System.user_home() do
      home when is_binary(home) and home != "" -> home
      _ -> nil
    end
  end

  defp data_dir do
    case {Application.fetch_env(:arbiter, :data_dir), System.get_env("ARB_DATA_HOME"),
          operator_home()} do
      {{:ok, dir}, _, _} when is_binary(dir) -> dir
      {_, dir, _} when is_binary(dir) and dir != "" -> dir
      {_, _, home} when is_binary(home) -> Path.join(home, ".arbiter")
      _ -> nil
    end
  end

  defp database do
    :arbiter |> Application.get_env(Arbiter.Repo, []) |> Keyword.get(:database)
  end

  defp unmask(opts, home) do
    opts
    |> Keyword.get_lazy(:unmask, fn -> Application.get_env(:arbiter, :worker_jail_unmask, []) end)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&expand(&1, home))
    |> Enum.map(&real/1)
    |> Enum.reject(&is_nil/1)
  end

  defp opt(opts, key, default_fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default_fun.()
    end
  end

  # ---- path handling -------------------------------------------------------

  defp join(nil, _rel), do: nil
  defp join(base, rel), do: Path.join(base, rel)

  defp expand(path), do: expand(path, operator_home())

  defp expand(path, home) when is_binary(path) do
    case path do
      "~" -> home
      "~/" <> rest when is_binary(home) -> Path.join(home, rest)
      _ -> path
    end
    |> case do
      p when is_binary(p) -> if Path.type(p) == :absolute, do: Path.expand(p), else: nil
      _ -> nil
    end
  end

  defp expand(_, _), do: nil

  # Existing paths only, each resolved to its real location.
  defp existing(paths, exists?) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&real/1)
    |> Enum.filter(&(is_binary(&1) and exists?.(&1)))
  end

  defp reject_unsafe(paths, home) do
    real_home = real(home)

    Enum.reject(paths, fn p ->
      p in ["/", "/tmp", "/run", "/dev", "/proc", "/sys", "/usr", "/etc", "/home"] or
        (real_home != nil and (p == real_home or under?(real_home, p)))
    end)
  end

  defp drop_nested(paths) do
    Enum.reject(paths, fn p -> Enum.any?(paths, &(&1 != p and under?(p, &1))) end)
  end

  defp under_any?(path, dirs), do: Enum.any?(dirs, &under?(path, &1))

  # `path` is strictly inside `dir`.
  defp under?(path, dir), do: String.starts_with?(path, dir <> "/")

  @doc false
  # Resolve every symlink in `path` (the BEAM has no realpath). Bounded, so a
  # symlink loop yields `nil` rather than hanging.
  @spec real(String.t() | nil) :: String.t() | nil
  def real(nil), do: nil

  def real(path) when is_binary(path) do
    path |> Path.expand() |> Path.split() |> resolve("/", 0)
  end

  defp resolve(_parts, _acc, depth) when depth > 40, do: nil
  defp resolve([], acc, _depth), do: acc
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([part | rest], acc, depth) do
    next = Path.join(acc, part)

    case File.read_link(next) do
      {:ok, target} ->
        target = Path.expand(target, acc)
        resolve(Path.split(target) ++ rest, "/", depth + 1)

      {:error, _} ->
        resolve(rest, next, depth)
    end
  end
end
