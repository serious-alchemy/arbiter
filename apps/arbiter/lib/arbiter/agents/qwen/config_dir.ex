defmodule Arbiter.Agents.Qwen.ConfigDir do
  @moduledoc """
  The per-worker `$HOME` a qwen spawn runs in (bd-2m67fw, Q3 of bd-3km00p).

  `QWEN_HOME` alone is **not** isolation: qwen also reads the operator's
  `~/.agents/skills` and spawns the MCP servers a repo's `.mcp.json` names. So
  a worker gets its own `HOME`, with `QWEN_HOME=$HOME/.qwen` inside it, and the
  operator's home is never on the spawn's env. Like `Arbiter.Agents.Grok.ConfigDir`
  there is no off switch.

  The directory is deterministic per worktree (`<root>/<worktree-key>`), so a
  respawn lands on the same home; a spawn with no worktree shares
  `<root>/default`. The root (`config :arbiter, :worker_qwen_home_root`) is a
  `Arbiter.Worker.Jail.Hide` root, so a jailed worker cannot read another
  worker's home.

  ## System settings

  Every `ensure/1` rewrites `<home>/.qwen-system/settings.json`, pointed at by
  `QWEN_CODE_SYSTEM_SETTINGS_PATH`. System settings outrank user and workspace
  settings in qwen, so a worker (or a repo) cannot loosen them from
  `$QWEN_HOME/settings.json`. The file is `0444`, written to a sibling and
  renamed over the target (a symlink a previous run planted is replaced, never
  written through), and lives outside `QWEN_HOME`; the jail (Q5) binds it
  read-only. It holds:

    * the deny baseline: `Read`/`Edit` denied on `Arbiter.Worker.CredentialPaths`;
    * managed memory and auto-dream off, telemetry off, usage statistics off;
    * update checks and the update nag off.

  ## Phone-home switches

  `QWEN_CODE_MODELS_DEV=off` (no models.dev catalogue fetch),
  `QWEN_USAGE_STATISTICS_ENABLED=false` (no RUM) and `DISABLE_AUTOUPDATER=1`.
  Operator-inherited qwen/provider variables that would redirect settings or
  hand a worker a credential are unset (`false`).
  """

  alias Arbiter.Worker.CredentialPaths

  require Logger

  @qwen_dir ".qwen"
  @system_dir ".qwen-system"
  @settings_file "settings.json"

  @phone_home_env [
    {"QWEN_CODE_MODELS_DEV", "off"},
    {"QWEN_USAGE_STATISTICS_ENABLED", "false"},
    {"DISABLE_AUTOUPDATER", "1"}
  ]

  # Inherited variables that redirect qwen's settings or carry a credential.
  @scrub_env ~w(
    QWEN_CODE_USER_SETTINGS_PATH QWEN_CODE_SYSTEM_DEFAULTS_PATH
    QWEN_CODE_TELEMETRY_ENABLED XDG_CONFIG_HOME XDG_DATA_HOME
    DASHSCOPE_API_KEY QWEN_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    ANTHROPIC_BASE_URL GEMINI_API_KEY GOOGLE_API_KEY
  )

  @doc "The isolated `$HOME` for a spawn: `<root>/<worktree-key>`."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Path.join(root(), key(worktree(opts)))

  @doc "The spawn's `QWEN_HOME`: `$HOME/.qwen`."
  @spec qwen_home(keyword()) :: String.t()
  def qwen_home(opts \\ []), do: Path.join(path(opts), @qwen_dir)

  @doc "The read-only system settings file, outside `QWEN_HOME`."
  @spec system_settings_path(keyword()) :: String.t()
  def system_settings_path(opts \\ []),
    do: Path.join([path(opts), @system_dir, @settings_file])

  @doc "The directory holding every worker's isolated home."
  @spec home_root() :: String.t()
  def home_root, do: root()

  @doc "The phone-home switches, as `{name, value}` pairs."
  @spec phone_home_env() :: [{String.t(), String.t()}]
  def phone_home_env, do: @phone_home_env

  @doc """
  The system settings as a map: deny baseline, memory / telemetry / update off.
  """
  @spec system_settings() :: map()
  def system_settings do
    %{
      "permissions" => %{"deny" => deny_baseline()},
      "memory" => %{"enableManagedAutoMemory" => false, "enableManagedAutoDream" => false},
      "telemetry" => %{"enabled" => false},
      "privacy" => %{"usageStatisticsEnabled" => false},
      "general" => %{
        "enableAutoUpdate" => false,
        "disableAutoUpdate" => true,
        "disableUpdateNag" => true
      }
    }
  end

  @doc """
  Ensure the home, its `.qwen` directory and the system settings exist;
  `{:ok, home}` or `{:error, reason}`. Idempotent.
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(opts \\ []) do
    home = path(opts)

    with :ok <- File.mkdir_p(home),
         :ok <- ensure_dir(Path.join(home, @qwen_dir)),
         :ok <- ensure_dir(Path.join(home, @system_dir)),
         :ok <- write_settings(system_settings_path(opts)) do
      {:ok, home}
    else
      {:error, reason} ->
        Logger.warning(
          "Arbiter.Agents.Qwen.ConfigDir: could not prepare isolated qwen HOME " <>
            "#{inspect(home)} (#{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc """
  `{:ok, env}` with the isolating `HOME` / `QWEN_HOME`, the system settings
  pointer, the phone-home switches and the scrubbed variables (the home is
  prepared first), or `{:error, reason}`.
  """
  @spec env(keyword()) :: {:ok, [{String.t(), String.t() | false}]} | {:error, term()}
  def env(opts \\ []) do
    with {:ok, home} <- ensure(opts) do
      {:ok, isolation_env(home, opts)}
    end
  end

  @doc """
  The same env without touching the filesystem, for callers that cannot fail
  (`spawn_env/1`). The paths are the ones `ensure/1` prepares.
  """
  @spec isolation_env(String.t(), keyword()) :: [{String.t(), String.t() | false}]
  def isolation_env(home, opts \\ []) do
    [
      {"HOME", home},
      {"QWEN_HOME", Path.join(home, @qwen_dir)},
      {"QWEN_CODE_SYSTEM_SETTINGS_PATH", system_settings_path(opts)}
    ] ++ @phone_home_env ++ Enum.map(@scrub_env, &{&1, false})
  end

  # ---- internals ---------------------------------------------------------

  defp deny_baseline do
    dirs = CredentialPaths.dirs()
    files = CredentialPaths.files()

    Enum.flat_map(dirs, &["Read(~/#{&1}/**)", "Edit(~/#{&1}/**)"]) ++
      Enum.flat_map(files, &["Read(~/#{&1})", "Edit(~/#{&1})"])
  end

  # Written to a sibling and renamed over the target, so a symlink (or a
  # read-only file) left at the target is replaced rather than written through.
  defp write_settings(path) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, Jason.encode!(system_settings(), pretty: true), [:exclusive]),
         :ok <- File.chmod(tmp, 0o444) do
      File.rename(tmp, path)
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  defp ensure_dir(dir) do
    with :ok <- unlink_if_symlink(dir), do: File.mkdir_p(dir)
  end

  defp unlink_if_symlink(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> File.rm(path)
      _ -> :ok
    end
  end

  defp root do
    Application.get_env(:arbiter, :worker_qwen_home_root) ||
      Path.join([cache_base(), "arbiter", "worker-qwen"])
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
end
