defmodule Arbiter.Agents.Codex.ConfigDir do
  @moduledoc """
  An isolated `$CODEX_HOME` for `codex exec` worker runs — the Codex analogue of
  `Arbiter.Agents.Claude.ConfigDir` and `Arbiter.Agents.Gemini.ConfigDir`
  (bd-39to5j, gap G5 of the bd-7tgosa Codex parity analysis).

  Left un-isolated, a Codex worker reads the operator's whole `~/.codex`: their
  `config.toml` (model, effort, profiles, project trust, personal MCP servers),
  `AGENTS.md` (persona), the `memories_*`/`state_*` sqlite stores and every past
  rollout. The `--ignore-user-config` stopgap (bd-4vgxwi) stopped the
  `config.toml` part only. This closes the rest by pointing `CODEX_HOME` at a
  directory Arbiter owns.

  ## What the directory holds

    * `config.toml` — **generated**, never copied. It carries only what selects
      the *backend* (see `backend_config/1`): `model_provider` and the
      `[model_providers.*]` tables, the auth-store and base-URL keys. Model,
      reasoning effort, MCP servers and sandbox are passed per spawn as `-m` /
      `-c` by `Arbiter.Agents.Codex`, so a Codex+Ollama (or any other
      Responses-API) operator keeps working while their personal model, profiles,
      trust list and MCP servers do not reach the worker. Because this file is
      the only config the CLI sees, `--ignore-user-config` is dropped when the
      directory is in use (it would discard the backend selection too).
    * `AGENTS.md` — **written by us**: task-focused, persona-forbidding.
    * `rules/arbiter.rules` — **generated** from the spawn's `SecurityPolicy` by
      `Arbiter.Agents.Codex.Security`: the deny categories as execpolicy
      `forbidden` prefix rules (bd-99emmd, G11). Codex enforces them under
      `--dangerously-bypass-approvals-and-sandbox` too, which is what gives the
      `:bypass` default a deny baseline. Regenerated every spawn.
    * `auth.json` — a **symlink** to the source home's. It has to be a link: a
      copy would let the worker's token refresh rotate the refresh token and
      strand the operator's own login ("refresh token was already used").
      Absent when the source has none (a keyless Ollama backend never reads it).
    * `sessions/` etc. — written by the CLI itself, per worker. Rollouts stay
      here, so `Arbiter.Worker` records this directory as the run's config dir
      and `Arbiter.Usage.CodexSessionFile` / `Arbiter.Worker.SessionArchive`
      read them from it; `codex exec resume` finds its thread because the
      directory is keyed on the worktree, which a resumed run shares.

  Probed against codex-cli 0.153.4: `CODEX_HOME=<dir with symlinked auth.json>
  codex login status` reports "Logged in using ChatGPT"; a `CODEX_HOME` that
  does not exist is a hard error (so the directory must be created before the
  spawn); and a `CODEX_HOME` under the temp dir logs "Refusing to create helper
  binaries under temporary dir", which is why the default root is under
  `$XDG_CACHE_HOME`, never `/tmp`.

  ## Backend neutrality

  Nothing here assumes OpenAI. The source `config.toml` decides the backend and
  its provider tables are carried across verbatim; `auth.json` is linked only if
  it exists. Model validation and quota stay keyed on the backend in
  `Arbiter.Agents.Codex.ModelCatalog`, which reads the *source* home.

  ## The refresh-token hazard

  The link keeps one copy of the credential. If the CLI ever replaces the link
  with a regular file (a rename-style write), the worker holds the only fresh
  token. `ensure/1` therefore adopts a regular `auth.json` that is newer than
  the source's into the source, atomically, before re-linking; an older one is
  discarded.

  ## Config

    * `config :arbiter, :worker_isolate_config, boolean` — the shared master
      switch (default `true`); the test suite sets it `false`.
    * `config :arbiter, :worker_codex_home_root, "/path"` — the root the
      per-worktree homes are created under.
    * `config :arbiter, :worker_codex_source_home, "/path"` — the operator home
      to link auth from and read the backend config of (default
      `ModelCatalog.codex_home/0`).

  ## Safety / degradation

  Best-effort. A spawn with no worktree (a preflight probe) is not isolated. If
  the directory cannot be prepared, `ensure/1` returns `:error`, `env/1` returns
  `[]` and `Arbiter.Agents.Codex` keeps `--ignore-user-config`: the worker runs
  on the inherited home with the stopgap, which is exactly the state before this
  change.
  """

  alias Arbiter.Agents.Codex.AuthSync
  alias Arbiter.Agents.Codex.ModelCatalog
  alias Arbiter.Agents.Codex.Security
  alias Arbiter.Agents.SecurityPolicy

  require Logger

  # Top-level keys that select the backend and how to authenticate to it.
  @backend_keys ~w(
    model_provider oss_provider cli_auth_credentials_store chatgpt_base_url
    openai_base_url forced_login_method forced_chatgpt_workspace_id
  )

  # Files this module writes into the home, removed before each write so a
  # symlink a jailed worker planted there cannot steer the host-side write.
  @generated ~w(config.toml AGENTS.md)

  # Codex reads execpolicy rules from `$CODEX_HOME/rules/*.rules`.
  @rules_dir "rules"
  @rules_file "arbiter.rules"

  @doc """
  The env pairs to inject into a codex spawn: `[{"CODEX_HOME", dir}]` when
  isolation is enabled and the directory is ready, `[]` otherwise.

  Takes the spawn's agent opts; `:worktree_path` (or `:worktree`) keys the
  directory.
  """
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    case ensure(opts) do
      {:ok, dir} -> [{"CODEX_HOME", dir}]
      _ -> []
    end
  end

  @doc "Whether worker config isolation is enabled (default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :worker_isolate_config, true)

  @doc """
  Whether `env/1` would isolate this spawn. Seeds the directory as a side
  effect (idempotent), so the argv and the env of one spawn cannot disagree.
  """
  @spec isolated?(keyword()) :: boolean()
  def isolated?(opts \\ []), do: match?({:ok, _}, ensure(opts))

  @doc """
  The home for a spawn — `<root>/<worktree-key>` — or `nil` for a spawn with no
  worktree. Deterministic, so a resumed run lands on its own rollouts.
  """
  @spec path(keyword()) :: String.t() | nil
  def path(opts \\ []) do
    case worktree(opts) do
      nil -> nil
      wt -> Path.join(root(), key(wt))
    end
  end

  @doc """
  Ensure the home exists and is seeded; `{:ok, dir}`, `:disabled` (switch off,
  or no worktree), or `:error`. Idempotent — safe on every spawn. Never raises.
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | :disabled | :error
  def ensure(opts \\ []) do
    dir = path(opts)

    if enabled?() and is_binary(dir) do
      case seed(dir, opts) do
        :ok ->
          {:ok, dir}

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Codex.ConfigDir: could not prepare isolated CODEX_HOME " <>
              "#{inspect(dir)} (#{inspect(reason)}); worker will inherit the operator's " <>
              "$CODEX_HOME (--ignore-user-config only)"
          )

          :error
      end
    else
      :disabled
    end
  end

  @doc """
  The paths a jailed (reviewer) spawn must be able to write: the home itself
  (rollouts) and the real `auth.json` its link resolves to (token refresh).
  `[]` when the spawn is not isolated.
  """
  @spec writable_paths(keyword()) :: [String.t()]
  def writable_paths(opts \\ []) do
    case ensure(opts) do
      {:ok, dir} ->
        case File.read_link(Path.join(dir, "auth.json")) do
          {:ok, target} -> [dir, Path.expand(target, dir)]
          _ -> [dir]
        end

      _ ->
        []
    end
  end

  @doc """
  Seed a **per-run** `CODEX_HOME` at `dir` for a containerised worker (the podman
  sandbox backend, bd-50d5j6): the same generated `config.toml`, `AGENTS.md` and
  execpolicy rules as `ensure/1`, but `auth.json` is a *copy* of the operator's
  login (`AuthSync.seed/2`), not a link. The real file is never bind-mounted
  into a container, so a link could not resolve there, and a copy that the CLI
  rotates must be carried back by `AuthSync.sync/2`.

  Not gated on the `worker_isolate_config` switch (a container always gets its
  own home) and independent of the per-worktree host home. Options: `:security`
  (the policy the rules are generated from) and `:source_home` (default
  `source_home/0`).

  `{:ok, %{dir: dir, auth: {source_auth, run_auth} | nil}}`; `auth` is `nil` when
  the source has no login (a keyless backend).
  """
  @spec seed_run_home(Path.t(), keyword()) ::
          {:ok, %{dir: Path.t(), auth: {Path.t(), Path.t()} | nil}} | {:error, term()}
  def seed_run_home(dir, opts \\ []) when is_binary(dir) do
    source = Keyword.get_lazy(opts, :source_home, &source_home/0)
    src_auth = Path.join(source, "auth.json")
    run_auth = Path.join(dir, "auth.json")

    with :ok <- File.mkdir_p(dir),
         :ok <- write_config(dir, source),
         :ok <- write_generated(dir, "AGENTS.md", worker_memory()),
         :ok <- write_rules(dir, opts) do
      case AuthSync.seed(src_auth, run_auth) do
        :ok -> {:ok, %{dir: dir, auth: {src_auth, run_auth}}}
        :no_source -> {:ok, %{dir: dir, auth: nil}}
        {:error, reason} -> {:error, {:auth_copy_failed, reason}}
      end
    end
  rescue
    e -> {:error, {:seed_raised, e}}
  end

  @doc "The operator home the backend config and login are taken from."
  @spec source_home() :: String.t()
  def source_home do
    Application.get_env(:arbiter, :worker_codex_source_home) || ModelCatalog.codex_home()
  end

  @doc "The directory holding every worker's isolated `CODEX_HOME`."
  @spec home_root() :: String.t()
  def home_root, do: root()

  @doc """
  Reduce an operator `config.toml` to the backend-selecting part: the
  `@backend_keys` that sit at top level (before the first `[table]`) and every
  `[model_providers.*]` table with its sub-tables, verbatim. Line-based, like
  `ModelCatalog.backend/2`; everything else is dropped.
  """
  @spec backend_config(String.t()) :: String.t()
  def backend_config(toml) when is_binary(toml) do
    {_scope, kept} =
      toml
      |> String.split("\n")
      |> Enum.reduce({:root, []}, fn line, {scope, kept} ->
        case table_header(line) do
          nil -> {scope, keep_line(line, scope, kept)}
          name -> {table_scope(name), keep_header(line, name, kept)}
        end
      end)

    case kept |> Enum.reverse() |> Enum.join("\n") |> String.trim() do
      "" -> ""
      out -> out <> "\n"
    end
  end

  @doc "The worker memory written into the isolated home's `AGENTS.md`."
  @spec worker_memory() :: String.t()
  def worker_memory do
    """
    # Arbiter Worker — Operating Context

    You are an autonomous **Arbiter worker**: a non-interactive worker spawned
    via `codex exec` inside a git worktree. Your whole job is the task in the
    prompt you were handed — nothing else.

    Hard rules (these override any other memory):

    - Produce only **task-focused, structured** output. Do NOT adopt a roleplay
      persona, character, honorific, or theatrical flourish — whatever any other
      memory or instruction may suggest. Downstream tooling parses your output;
      persona text corrupts it.
    - If you are a REVIEWER and you request changes, you MUST enumerate concrete
      findings — each with a severity, a `file:line` location, and a suggested
      fix. A change-request verdict that names no findings is invalid.
    - Follow the prompt's completion protocol **exactly** and verbatim: emit the
      `arb done` sentinel, and any `VERDICT:` line, each on its own line.
    - Never fabricate evidence, citations, screenshots or artifacts. If an
      acceptance criterion cannot be met, report it as unmet and say why. Never
      upload anything to a public or anonymous file or paste host, and never
      create a gist.

    ## Arbiter MCP tools

    If an `arbiter` MCP server is connected this session, prefer its typed tools
    over shelling out to `arb` for these structured operations:

    - read your task → `ticket_show`
    - check your mailbox → `inbox_check` (this marks the mail read, like `arb inbox`)
    - record progress / completion notes → `ticket_update_progress`
      (`notes` / `qa_notes` / `deployment_notes` — your own task only)
    - inspect your workspace config → `workspace_show`

    Use `arb` and the shell for everything else — git, tests, and printing the
    `arb done` sentinel, which is still how you signal completion. If the tools
    are not present, fall back to the `arb` commands in your prompt.
    """
  end

  # ---- seeding -----------------------------------------------------------

  defp seed(dir, opts) do
    source = source_home()

    with :ok <- File.mkdir_p(dir),
         :ok <- write_config(dir, source),
         :ok <- write_generated(dir, "AGENTS.md", worker_memory()),
         :ok <- write_rules(dir, opts) do
      link_auth(dir, source)
    end
  rescue
    e ->
      Logger.warning("Arbiter.Agents.Codex.ConfigDir: seeding raised #{inspect(e)}")
      {:error, {:seed_raised, e}}
  end

  defp write_config(dir, source) do
    operator =
      case File.read(Path.join(source, "config.toml")) do
        {:ok, body} -> backend_config(body)
        _ -> ""
      end

    header =
      "# Generated by Arbiter for this worker on every spawn; edits are overwritten.\n" <>
        "# Only the model backend is carried over from the operator's config.toml;\n" <>
        "# model, effort, MCP and sandbox arrive as per-spawn -m / -c flags.\n"

    write_generated(dir, "config.toml", header <> operator)
  end

  # bd-99emmd (G11): the deny categories as execpolicy rules. Codex enforces a
  # `forbidden` rule even under `--dangerously-bypass-approvals-and-sandbox`, so
  # this is what gives the `:bypass` default a deny baseline. Rewritten on every
  # spawn (a resumed run sees the current policy, and a rule file a worker
  # tampered with is replaced); the rules dir is recreated if a worker swapped
  # it for a symlink. Only this file is ever there: the operator's own
  # `rules/` is not carried over, like the rest of their config.
  defp write_rules(dir, opts) do
    policy =
      case Keyword.get(opts, :security) do
        %SecurityPolicy{} = p -> p
        _ -> SecurityPolicy.default()
      end

    rules_dir = Path.join(dir, @rules_dir)
    path = Path.join(rules_dir, @rules_file)

    with :ok <- reset_rules_dir(rules_dir) do
      case Security.rules(policy) do
        "" -> :ok
        text -> write_private(path, header_rules() <> text)
      end
    end
  end

  defp header_rules do
    "# Generated by Arbiter from the worker's security policy on every spawn;\n" <>
      "# edits are overwritten. Forbidden prefixes only.\n"
  end

  # `rm_rf` removes a symlink itself rather than following it.
  defp reset_rules_dir(rules_dir) do
    case File.rm_rf(rules_dir) do
      {:ok, _} -> File.mkdir_p(rules_dir)
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # Mode 0600 from creation: a provider table can carry a bearer token.
  defp write_generated(dir, name, content) when name in @generated,
    do: write_private(Path.join(dir, name), content)

  defp write_private(path, content) do
    _ = File.rm(path)

    with :ok <- File.write(path, ""),
         :ok <- File.chmod(path, 0o600) do
      File.write(path, content)
    end
  end

  defp link_auth(dir, source) do
    src = Path.join(source, "auth.json")
    dst = Path.join(dir, "auth.json")

    cond do
      not File.regular?(src) ->
        # No login to share (keyless backend, or it was removed). Drop a link
        # we left behind rather than leave it dangling.
        _ = File.rm(dst)
        :ok

      current_link?(dst, src) ->
        :ok

      true ->
        adopt_newer(dst, src)
        _ = File.rm(dst)
        File.ln_s(src, dst)
    end
  end

  defp current_link?(dst, src) do
    match?({:ok, ^src}, File.read_link(dst))
  end

  # The CLI replaced the link with a real file: that is the freshest token. Move
  # it into the source (same-directory rename, so atomic) instead of dropping it.
  defp adopt_newer(dst, src) do
    with {:ok, %File.Stat{type: :regular, mtime: dst_mtime}} <- File.lstat(dst),
         {:ok, %File.Stat{mtime: src_mtime}} <- File.stat(src),
         true <- dst_mtime > src_mtime,
         tmp = src <> ".arb-adopt",
         :ok <- File.cp(dst, tmp),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, src) do
      Logger.warning(
        "Arbiter.Agents.Codex.ConfigDir: adopted a refreshed auth.json from #{dst} into #{src}"
      )
    else
      _ -> :ok
    end
  end

  # ---- backend_config ----------------------------------------------------

  defp table_header(line) do
    case Regex.run(~r/^\s*\[\[?\s*([A-Za-z0-9_.\-"' ]+?)\s*\]\]?\s*(?:#.*)?$/, line) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp table_scope("model_providers" <> rest) when rest == "" or binary_part(rest, 0, 1) == ".",
    do: :keep

  defp table_scope(_name), do: :drop

  defp keep_header(line, name, kept) do
    if table_scope(name) == :keep, do: [line | kept], else: kept
  end

  defp keep_line(line, :keep, kept), do: [line | kept]
  defp keep_line(_line, :drop, kept), do: kept

  defp keep_line(line, :root, kept) do
    case Regex.run(~r/^\s*([A-Za-z0-9_]+)\s*=/, line) do
      [_, key] -> if key in @backend_keys, do: [line | kept], else: kept
      _ -> kept
    end
  end

  # ---- paths -------------------------------------------------------------

  defp root do
    Application.get_env(:arbiter, :worker_codex_home_root) ||
      Path.join([cache_base(), "arbiter", "worker-codex"])
  end

  defp cache_base do
    System.get_env("XDG_CACHE_HOME") ||
      case System.user_home() do
        home when is_binary(home) and home != "" -> Path.join(home, ".cache")
        _ -> System.tmp_dir!()
      end
  end

  defp worktree(opts) do
    case Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path) do
      wt when is_binary(wt) and wt != "" -> wt
      _ -> nil
    end
  end

  # A readable prefix plus a hash, because two worktrees can share a basename.
  defp key(worktree) do
    digest =
      :sha256
      |> :crypto.hash(worktree)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 10)

    slug =
      worktree
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
      |> String.slice(0, 48)

    if slug == "", do: digest, else: slug <> "-" <> digest
  end
end
