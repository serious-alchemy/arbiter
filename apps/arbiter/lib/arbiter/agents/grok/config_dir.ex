defmodule Arbiter.Agents.Grok.ConfigDir do
  @moduledoc """
  The per-worker `$HOME` a grok spawn runs in (bd-9ydvov).

  grok keeps its login, sessions and config in `$GROK_HOME` (default
  `~/.grok`), but setting `GROK_HOME` alone is **not** isolation: grok's
  Claude/Cursor compatibility layer still reads the operator's `~/.claude`
  (`settings.json` permission rules and hooks, `~/.claude.json` MCP servers,
  skills, plugins). bd-73uvlo measured it: with only `GROK_HOME` overridden
  `grok inspect` loaded 19 permission rules, a hook, two MCP servers and 20
  skills; with `HOME` overridden too, all were zero. So a worker gets its own
  `HOME`, with `GROK_HOME=$HOME/.grok` inside it, and the operator's home is
  never on the spawn's env.

  Unlike `Arbiter.Agents.Gemini.ConfigDir` this has no off switch: an
  un-isolated grok worker would run with the operator's hooks and MCP servers,
  so the spawn is refused instead (`Arbiter.Agents.Grok.default_argv/2`).

  The directory is deterministic per worktree (`<root>/<worktree-key>`), so the
  spawn, the MCP config writer (a follow-up) and a respawn all land on the same
  home; a spawn with no worktree (an auth probe) shares `<root>/default`. It is
  also the only place a jailed grok may write besides the worktree, so it holds
  the prompt file for an oversize prompt (the jail's `--tmpfs /tmp` hides
  `/tmp`). The credential is *not* seeded here: it arrives through
  `Arbiter.Agents.Grok.Credential`, never as a copied refresh token.
  """

  require Logger

  @grok_dir ".grok"
  @prompt_dir "prompts"

  @doc "The isolated `$HOME` for a spawn: `<root>/<worktree-key>`."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []), do: Path.join(root(), key(worktree(opts)))

  @doc "The spawn's `GROK_HOME`: `$HOME/.grok`."
  @spec grok_home(keyword()) :: String.t()
  def grok_home(opts \\ []), do: Path.join(path(opts), @grok_dir)

  @doc "The directory holding every worker's isolated home."
  @spec home_root() :: String.t()
  def home_root, do: root()

  @doc """
  Ensure the home and its `.grok` directory exist; `{:ok, home}` or
  `{:error, reason}`. Idempotent.

  A jailed worker can write anywhere in its home, and everything here runs on
  the host at the next spawn, so a symlink it planted where `.grok` or the
  prompt directory goes is removed rather than followed.
  """
  @spec ensure(keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure(opts \\ []) do
    home = path(opts)

    with :ok <- File.mkdir_p(home),
         :ok <- ensure_dir(Path.join(home, @grok_dir)),
         :ok <- ensure_dir(Path.join(home, @prompt_dir)) do
      {:ok, home}
    else
      {:error, reason} ->
        Logger.warning(
          "Arbiter.Agents.Grok.ConfigDir: could not prepare isolated grok HOME " <>
            "#{inspect(home)} (#{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc """
  `{:ok, env}` with the isolating `HOME` / `GROK_HOME` pair (the home is
  prepared first), or `{:error, reason}`.
  """
  @spec env(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def env(opts \\ []) do
    with {:ok, home} <- ensure(opts) do
      {:ok, [{"HOME", home}, {"GROK_HOME", Path.join(home, @grok_dir)}]}
    end
  end

  @doc """
  Write `prompt` to a fresh `0600` file under the home and return its path, for
  `grok --prompt-file` when the prompt is too large for one argv element.
  """
  @spec write_prompt_file(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write_prompt_file(prompt, opts \\ []) when is_binary(prompt) do
    with {:ok, home} <- ensure(opts) do
      file = "prompt-#{System.unique_integer([:positive])}.txt"
      path = Path.join([home, @prompt_dir, file])

      with :ok <- File.write(path, prompt, [:exclusive]),
           :ok <- File.chmod(path, 0o600) do
        {:ok, path}
      end
    end
  end

  # ---- internals ---------------------------------------------------------

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
    Application.get_env(:arbiter, :worker_grok_home_root) ||
      Path.join([cache_base(), "arbiter", "worker-grok"])
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

  # A readable slug (greppable by a human) plus a hash, because two worktrees
  # can share a basename.
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
