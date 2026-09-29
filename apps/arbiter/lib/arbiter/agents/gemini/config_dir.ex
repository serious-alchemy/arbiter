defmodule Arbiter.Agents.Gemini.ConfigDir do
  @moduledoc """
  An isolated `$HOME` for `agy` (Antigravity) worker runs — the agy analogue of
  `Arbiter.Agents.Claude.ConfigDir` (bd-7s29yq / T6b, implementing the T6a
  spike's decision).

  ## Why `$HOME` and not a config-dir env var

  Claude gets `CLAUDE_CONFIG_DIR`; agy has nothing like it. The T6a spike
  (bd-83hjke) disassembled the binary and probed it live: there is **no**
  `AGY_*` / `GEMINI_*` config-root override, `--app_data_dir` only relocates
  the conversation/cache tree *within* `~/.gemini`, and every configuration
  input agy reads — `~/.gemini/antigravity-cli/settings.json` (permission
  posture), `~/.gemini/GEMINI.md` (user memory), `~/.gemini/config/skills/`,
  `~/.gemini/config/plugins/`, `~/.gemini/config/mcp_config.json` — is resolved
  from `$HOME`. Redirecting `HOME` is therefore the only per-spawn lever.

  Left un-isolated, an agy worker inherits the operator's
  `toolPermission: "always-proceed"` with no deny list, the operator's personal
  `GEMINI.md`, and the operator's skills/plugins. Probing confirmed both halves:
  a `GEMINI.md` planted in a throwaway `$HOME` *did* steer the model's output,
  which is exactly the bd-3y2mda persona hazard on the agy side.

  ## How

  `env/1` returns `[{"HOME", dir}]`; `ensure/1` seeds `dir` idempotently on
  every spawn:

    * `.gemini/antigravity-cli/settings.json` — **generated** from the spawn's
      `Arbiter.Agents.SecurityPolicy` by `Arbiter.Agents.Gemini.Security`, never
      copied. Rewritten on every spawn so a stale posture cannot linger.
    * `.gemini/GEMINI.md` — **written by us**, task-focused, persona-forbidding.
    * `.gemini/config/mcp_config.json` — written by `write_mcp_config/2` when
      the dispatch has an MCP scope token to hand out (bd-m8geh4 confirmed agy
      reads this path and this schema; `Arbiter.MCP.AgentConfig.Gemini`
      generates the document).
    * everything else in the operator's `$HOME` is **symlinked through**, except
      the three trees we deliberately shadow: `.gemini` (agy's own config — the
      whole point), `.agents` (agy's user-level skills/plugins/rules) and
      `.antigravity`.

  ### Why symlink the passthrough

  A worker still has to `git commit`, `gh`, `mix test` and `arb` — which need
  `.gitconfig`, `.ssh`, `.config/gh`, `.local`, `.cache/mix`, `.hex`, `.mix`,
  `.arbiter`. Copying all of that per worker is a cold-cache tax on every spawn
  and (for `.ssh`) would scatter copies of the operator's private keys across
  `~/.cache`. Symlinks keep exactly one copy of each and make this change
  *strictly* no worse than the status quo for everything except `.gemini`,
  which is the only thing we are here to isolate. Workers run as the same OS
  user either way — this is a config-inheritance boundary, not a security
  boundary against a hostile process.

  ### Credentials

  On a host with a working freedesktop Secret Service (D-Bus), agy stores its
  live Google grant in the **keyring**, not in `~/.gemini` — the spike proved a
  brand-new `$HOME` with zero credential files still authenticates. The keyring
  is scoped to the Linux user session, not to `$HOME`, so it survives the
  redirect untouched and there is nothing to seed. `keyring_available?/0`
  detects that case; only when no Secret Service is reachable do we **copy**
  (never symlink — a worker refreshing through a link would corrupt the
  operator's login) `oauth_creds.json`, `jetski-standalone-oauth-token` and
  `google_accounts.json`.

  ## Keyed per worktree

  Unlike the Claude config dir (one install-wide directory) this is keyed on the
  spawn's worktree. Two things force it: the generated `settings.json` carries
  a **per-workspace** posture, and `mcp_config.json` carries a **per-task**
  scope token — one shared directory would have concurrent agy workers
  overwriting each other's posture and token. Keying on the worktree also means
  `write_mcp_config/2` (called from dispatch, before the spawn) and `env/1`
  (called at spawn) independently compute the same directory without having to
  pass a handle between them.

  ## Config

    * `config :arbiter, :worker_isolate_config, boolean` — the shared master
      switch (default `true`); the test suite sets it `false`.
    * `config :arbiter, :worker_agy_home_root, "/path"` — override the root the
      per-worktree homes are created under.
    * `config :arbiter, :worker_agy_source_home, "/path"` — override the
      operator `$HOME` we pass through (tests).

  ## Safety / degradation

  Best-effort throughout. If the directory cannot be prepared, `ensure/1`
  returns `:error` and `env/1` returns `[]` — the worker runs against the
  inherited (un-isolated) `$HOME`, which is exactly today's behaviour. A
  working-but-un-isolated worker beats a broken one.
  """

  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy

  require Logger

  # Shadowed, never passed through: everything agy reads its own configuration,
  # memory, skills and plugins from.
  @shadowed ~w(.gemini .agents .antigravity)

  # Copied (never symlinked) only when no Secret Service keyring is reachable.
  @credential_files ~w(oauth_creds.json jetski-standalone-oauth-token google_accounts.json)

  @gemini_dir ".gemini"
  @settings_path Path.join([".gemini", "antigravity-cli", "settings.json"])
  @memory_path Path.join(".gemini", "GEMINI.md")
  @mcp_config_path Path.join([".gemini", "config", "mcp_config.json"])
  @onboarding_path Path.join([".gemini", "antigravity-cli", "cache", "onboarding.json"])

  @doc """
  The env pairs to inject into an agy spawn: `[{"HOME", dir}]` when isolation is
  enabled and the directory is ready, `[]` otherwise (inherit the host `$HOME`
  unchanged).

  Accepts the spawn's agent opts — `:worktree` (or `:worktree_path`) keys the
  directory and `:security` supplies the posture baked into `settings.json`.
  """
  @spec env(keyword()) :: [{String.t(), String.t()}]
  def env(opts \\ []) do
    case ensure(opts) do
      {:ok, dir} -> [{"HOME", dir}]
      _ -> []
    end
  end

  @doc "Whether worker config isolation is enabled (default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :worker_isolate_config, true)

  @doc """
  The isolated `$HOME` for a spawn — `<root>/<worktree-key>`, or `<root>/default`
  for a spawn with no worktree in hand (a preflight/quota probe).

  Deterministic: the dispatch-time MCP writer and the spawn itself both land on
  the same directory from the same worktree.
  """
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Path.join(root(), key(worktree(opts)))

  @doc """
  Ensure the isolated `$HOME` exists and is seeded; return `{:ok, dir}`.

  Returns `:disabled` when isolation is switched off, `:error` when the
  directory could not be prepared. Idempotent — safe on every spawn.

  Options: `:worktree` / `:worktree_path`, `:security` (a `SecurityPolicy`),
  and `:keyring` (a boolean override for `keyring_available?/0`, for tests).
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | :disabled | :error
  def ensure(opts \\ []) do
    if enabled?() do
      dir = path(opts)

      case seed(dir, opts) do
        :ok ->
          {:ok, dir}

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Gemini.ConfigDir: could not prepare isolated agy HOME " <>
              "#{inspect(dir)} (#{inspect(reason)}); worker will inherit the operator's " <>
              "$HOME — including their ~/.gemini permission posture and GEMINI.md"
          )

          :error
      end
    else
      :disabled
    end
  end

  @doc """
  Seed `dir` as an agy `$HOME`, unconditionally — the part of `ensure/1` that
  does not decide *whether* or *where* to isolate.

  `ensure/1` calls it for a worker (gated on `enabled?/0`, keyed on the
  worktree). A browser session (`Arbiter.Sessions.Provisioning`, bd-7xuvfl)
  calls it directly for its own `<session>/home`: a session's `$HOME` is not
  optional — its MCP token has nowhere else to go that agy reads — so the
  worker master switch does not apply.

  Options, on top of `ensure/1`'s `:worktree` / `:security` / `:keyring`:

    * `:memory` — the `.gemini/GEMINI.md` content; defaults to
      `worker_memory/0`, which is headless-worker doctrine and wrong for
      anything interactive.
    * `:source_home` — the operator `$HOME` to pass through; defaults to
      `source_home/0`.
    * `:boundary` — the directory `dir` is created under (default: the worker
      home root). It is never linked, and an operator-`$HOME` entry containing
      it is mirrored rather than linked, so `dir` can never end up inside
      itself.
    * `:interactive` — `true` also carries the operator's agy onboarding state
      (`antigravity-cli/cache/onboarding.json`) over. Observed live on agy
      1.2.12: with a fresh `.gemini`, `agy --prompt-interactive` opens on a
      "Choose your color scheme" wizard instead of running its prompt, and
      that file's `onboardingComplete` is what gates it. Headless `agy -p`
      never shows the wizard, so a worker leaves it alone. Copied, not
      written, so a consumer vs. enterprise account keeps its own answer; an
      operator who never onboarded agy gets the wizard, which is honest.

  Returns `:ok` or `{:error, reason}`. Never raises.
  """
  @spec seed(String.t(), keyword()) :: :ok | {:error, term()}
  def seed(dir, opts \\ []) when is_binary(dir) do
    unlink_planted_links(dir)

    with :ok <- File.mkdir_p(Path.join(dir, Path.dirname(@settings_path))),
         :ok <- write_settings(dir, opts),
         :ok <- write_memory(dir, Keyword.get(opts, :memory, worker_memory())) do
      passthrough(dir, opts)
      seed_credentials(dir, opts)
      if Keyword.get(opts, :interactive, false), do: seed_onboarding(dir, opts)
      :ok
    end
  rescue
    e ->
      Logger.warning("Arbiter.Agents.Gemini.ConfigDir: seeding raised #{inspect(e)}")
      {:error, {:seed_raised, e}}
  end

  @doc """
  Write an agy MCP config document into the spawn's isolated `HOME`
  (`<home>/.gemini/config/mcp_config.json`) — the only path agy reads MCP
  servers from (bd-m8geh4).

  Returns `{:ok, path}`, or `{:error, :disabled}` when there is no
  Arbiter-owned `HOME` to write into (isolation off) — writing the operator's
  own `~/.gemini/config/mcp_config.json` instead is never acceptable: it would
  put a per-task scope token into the file the operator's interactive agy
  sessions read.
  """
  @spec write_mcp_config(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_mcp_config(config, opts \\ []) when is_map(config) do
    case ensure(opts) do
      {:ok, dir} ->
        write_mcp_config_into(dir, config)

      :disabled ->
        {:error, :disabled}

      :error ->
        {:error, :unavailable}
    end
  end

  @doc """
  Write an agy MCP config document into an already-seeded agy `$HOME` `dir`,
  at `<dir>/.gemini/config/mcp_config.json`, mode `0600` from creation — it
  carries a live bearer token. The primitive under `write_mcp_config/2`, public
  for a caller that owns its `$HOME` outright (a browser session, bd-7xuvfl).
  """
  @spec write_mcp_config_into(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_mcp_config_into(dir, config) when is_binary(dir) and is_map(config) do
    path = Path.join(dir, @mcp_config_path)

    _ = File.rm(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, ""),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, Jason.encode!(config, pretty: true)) do
      {:ok, path}
    end
  end

  @doc "Where `write_mcp_config_into/2` writes, relative to the agy `$HOME`."
  @spec mcp_config_path() :: String.t()
  def mcp_config_path, do: @mcp_config_path

  @doc """
  Whether a freedesktop Secret Service is reachable for this OS user.

  When it is, agy's live credential lives in the keyring — which `$HOME`
  redirection does not touch — and seeding credential files is both unnecessary
  and a rotation hazard. See the moduledoc.
  """
  @spec keyring_available?() :: boolean()
  def keyring_available? do
    case System.get_env("DBUS_SESSION_BUS_ADDRESS") do
      "unix:path=" <> rest -> rest |> String.split(",") |> hd() |> File.exists?()
      addr when is_binary(addr) and addr != "" -> true
      _ -> false
    end
  end

  @doc "The worker memory written into the isolated HOME's `.gemini/GEMINI.md`."
  @spec worker_memory() :: String.t()
  def worker_memory do
    """
    # Arbiter Worker — Operating Context

    You are an autonomous **Arbiter worker**: a non-interactive `agy --print`
    session running inside a git worktree. Your whole job is the task in the
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
    - Long commands (`mix test`, `mix precommit`, `mix dialyzer`, `git push`)
      go to the background. Launch them, then end your turn: agy keeps the
      session alive for up to 30 minutes and wakes you with a system message
      when the task finishes. Do not poll it with `manage_task`, re-read its
      log, or `sleep` in a loop.
    - Run one command per `run_command` call. Under a restricted permission
      policy every part of a chained command (`a && b`, `a; b`, `a | b`) must
      be allowed, and a denied command ends your turn. Do not retry a denied
      command or work around it: carry on without it, and note what you could
      not do in your findings.
    - Never fabricate evidence, citations, screenshots or artifacts. A
      screenshot is a real capture of the real app; a citation names where the
      thing actually came from. If an acceptance criterion cannot be met
      (screenshots are not possible headlessly, an official asset cannot be
      found), report it as unmet and say why. That is always acceptable; a
      mockup passed off as a screenshot is not. Do not change a true statement
      to satisfy a reviewer.
    - Never upload anything to a public or anonymous file or paste host
      (catbox.moe, 0x0.st, transfer.sh, file.io, pastebin and the like), never
      create a gist, and never post test comments on issues or PRs.

    ## Arbiter MCP tools

    If an `arbiter` MCP server is connected this session, prefer its typed tools
    over shelling out to `arb`: `ticket_show`, `inbox_check`,
    `ticket_update_progress`, `workspace_show`. Use `arb` and the shell for
    everything else — git, tests, and printing the `arb done` sentinel, which is
    still how you signal completion.
    """
  end

  @doc "The operator `$HOME` whose non-agy entries we pass through."
  @spec source_home() :: String.t() | nil
  def source_home do
    Application.get_env(:arbiter, :worker_agy_source_home) ||
      case System.user_home() do
        home when is_binary(home) and home != "" -> home
        _ -> nil
      end
  end

  @doc "The top-level entries of the operator's HOME that are never passed through."
  @spec shadowed() :: [String.t()]
  def shadowed, do: @shadowed

  # ---- internals ---------------------------------------------------------

  defp root do
    Application.get_env(:arbiter, :worker_agy_home_root) ||
      Path.join([cache_base(), "arbiter", "worker-agy"])
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

  # A readable prefix (so the directory is greppable by a human debugging a
  # run) plus a hash, because two worktrees can share a basename.
  defp key(nil), do: "default"

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

  # bd-5gvqgc: a jailed agy worker can write anywhere in this HOME, and every
  # write here runs on the host, unjailed, at the next spawn. A symlink it
  # planted where one of our directories goes would steer those writes
  # anywhere the operator can write, so remove it rather than follow it. The
  # files themselves are removed before each write for the same reason.
  @owned_dirs [
    @gemini_dir,
    Path.dirname(@settings_path),
    Path.dirname(@mcp_config_path),
    Path.dirname(@onboarding_path)
  ]

  defp unlink_planted_links(dir) do
    Enum.each(@owned_dirs, fn rel ->
      path = Path.join(dir, rel)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> File.rm(path)
        _ -> :ok
      end
    end)
  end

  # Always (re)write the generated settings so the posture can never drift from
  # the policy this spawn resolved.
  defp write_settings(dir, opts) do
    path = Path.join(dir, @settings_path)
    _ = File.rm(path)
    File.write(path, Security.settings_json(policy(opts), worktree: worktree(opts), home: dir))
  end

  defp policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  defp write_memory(dir, memory) do
    path = Path.join(dir, @memory_path)
    _ = File.rm(path)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, memory)
    end
  end

  # Symlink every top-level entry of the operator's HOME except the trees we
  # shadow. Idempotent: an existing correct link is left alone, a stale one is
  # replaced, and anything we own (`.gemini`) is never touched.
  defp passthrough(dir, opts) do
    boundary = Keyword.get(opts, :boundary) || root()

    case Keyword.get_lazy(opts, :source_home, &source_home/0) do
      nil ->
        :ok

      src ->
        case File.ls(src) do
          {:ok, entries} ->
            entries
            |> Enum.reject(&(&1 in @shadowed))
            |> Enum.each(&link_one(src, dir, &1, boundary))

          {:error, reason} ->
            Logger.warning(
              "Arbiter.Agents.Gemini.ConfigDir: could not list #{inspect(src)} " <>
                "(#{inspect(reason)}); the worker HOME has no passthrough entries"
            )
        end
    end
  end

  defp link_one(src, dir, name, boundary) do
    target = Path.join(src, name)
    link = Path.join(dir, name)

    cond do
      # The entry *is* the home root (`<cache>/arbiter/worker-agy`, or a
      # session's sessions root): linking it would put this HOME inside
      # itself. Drop it.
      same_path?(target, boundary) ->
        :ok

      # The entry *contains* the home root. The default root lives under
      # `~/.cache`, i.e. inside the operator's HOME, so a flat link would make
      # `<home>/.cache -> ~/.cache` and `<home>/.cache/arbiter/worker-agy/<key>`
      # resolve straight back to `<home>` — an unbounded symlink cycle rooted in
      # the worker's own HOME that any `du -L` / `rg --follow` / `cp -rL` the
      # worker runs would walk until ELOOP. Mirror the directory instead and
      # link its children, so `~/.cache/mix` & friends stay reachable.
      root_under?(target, boundary) ->
        descend(target, link, boundary)

      true ->
        do_link(target, link)
    end
  end

  # Recreate `target` as a real directory under the worker HOME and pass its
  # children through individually — recursing while the root is still below us,
  # and never linking the root itself (see `link_one/4`).
  defp descend(target, link, boundary) do
    # A HOME seeded before this rule existed still carries the cycle as a plain
    # symlink; replace it with a real directory.
    if match?({:ok, %{type: :symlink}}, File.lstat(link)), do: File.rm(link)

    with :ok <- File.mkdir_p(link),
         {:ok, entries} <- File.ls(target) do
      Enum.each(entries, &link_one(target, link, &1, boundary))
    else
      _ -> :ok
    end
  end

  defp do_link(target, link) do
    case File.read_link(link) do
      {:ok, ^target} ->
        :ok

      _ ->
        _ = File.rm(link)

        case File.ln_s(target, link) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug(
              "Arbiter.Agents.Gemini.ConfigDir: could not link #{inspect(link)} -> " <>
                "#{inspect(target)} (#{inspect(reason)})"
            )
        end
    end
  end

  defp same_path?(a, b), do: Path.expand(a) == Path.expand(b)

  defp root_under?(path, boundary),
    do: String.starts_with?(Path.expand(boundary), Path.expand(path) <> "/")

  # See the moduledoc: with a keyring there is nothing to seed, and seeding
  # anyway would hand the worker a refreshable copy of the operator's grant.
  defp seed_credentials(dir, opts) do
    keyring? = Keyword.get(opts, :keyring, keyring_available?())
    home = Keyword.get_lazy(opts, :source_home, &source_home/0)

    cond do
      keyring? ->
        :ok

      is_nil(home) ->
        :ok

      true ->
        Enum.each(@credential_files, &copy_credential(dir, home, &1))
    end
  end

  defp copy_credential(dir, home, name) do
    src = Path.join([home, @gemini_dir, name])
    dst = Path.join([dir, @gemini_dir, name])

    if File.regular?(src) and not fresh_copy?(src, dst) do
      _ = File.rm(dst)

      case File.cp(src, dst) do
        :ok ->
          _ = File.chmod(dst, 0o600)
          :ok

        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Gemini.ConfigDir: could not seed #{inspect(dst)} " <>
              "(#{inspect(reason)}); this agy worker may be unauthenticated"
          )
      end
    end
  end

  # The file itself is removed first and its directory is one of
  # `@owned_dirs`, so a link planted at either is never written through.
  defp seed_onboarding(dir, opts) do
    with home when is_binary(home) <- Keyword.get_lazy(opts, :source_home, &source_home/0),
         src = Path.join(home, @onboarding_path),
         true <- File.regular?(src) do
      dst = Path.join(dir, @onboarding_path)
      _ = File.rm(dst)

      with :ok <- File.mkdir_p(Path.dirname(dst)),
           :ok <- File.cp(src, dst) do
        :ok
      else
        {:error, reason} ->
          Logger.warning(
            "Arbiter.Agents.Gemini.ConfigDir: could not seed #{inspect(dst)} " <>
              "(#{inspect(reason)}); agy will open on its onboarding wizard"
          )
      end
    else
      _ -> :ok
    end
  end

  defp fresh_copy?(src, dst) do
    case {File.lstat(src), File.lstat(dst)} do
      {{:ok, %{type: :regular, mtime: sm}}, {:ok, %{type: :regular, mtime: dm}}} -> dm >= sm
      _ -> false
    end
  end
end
