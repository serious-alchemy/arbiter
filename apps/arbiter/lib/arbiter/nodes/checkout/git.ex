defmodule Arbiter.Nodes.Checkout.Git do
  @moduledoc """
  The one place checkout sync (`docs/design/remote-workers.md` §9) spawns `git`.

  Everything that touches a repo whose content a node (or the container on it)
  could have shaped goes through here, so the same defences apply to every call:

    * the user's and the system's git config are ignored;
    * `core.hooksPath=/dev/null`, `core.fsmonitor=false`, `gc.auto=0` and no
      pager or editor, so no hook, fsmonitor or auto-gc runs;
    * no terminal prompt and no optional locks;
    * a fixed author/committer identity, so `commit-tree` needs no config.

  `git_dir:` / `work_tree:` are passed as `--git-dir` / `--work-tree`, so a
  command can run against a bare quarantine with a scratch work tree (or none),
  and never discovers a repo from the current directory.
  """

  @safety ~w(-c core.hooksPath=/dev/null -c core.fsmonitor=false -c gc.auto=0
             -c core.pager=cat -c core.editor=true -c protocol.ext.allow=never
             -c protocol.file.allow=always)

  @type result :: {:ok, String.t()} | {:error, {:git, non_neg_integer(), String.t()}}

  @doc """
  Run `git args`. Options: `:git_dir`, `:work_tree`, `:cd` (default: the system
  temp dir, never a repo), `:env` (extra `{name, value}` pairs, e.g.
  `GIT_INDEX_FILE`). Output is stdout and stderr merged, with trailing
  whitespace trimmed.
  """
  @spec run([String.t()], keyword()) :: result()
  def run(args, opts \\ []) when is_list(args) do
    prefix =
      @safety ++ dir_flag("--git-dir", opts[:git_dir]) ++ dir_flag("--work-tree", opts[:work_tree])

    env =
      [
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_OPTIONAL_LOCKS", "0"},
        {"GIT_LITERAL_PATHSPECS", "1"},
        {"GIT_AUTHOR_NAME", "arbiter"},
        {"GIT_AUTHOR_EMAIL", "arbiter@localhost"},
        {"GIT_COMMITTER_NAME", "arbiter"},
        {"GIT_COMMITTER_EMAIL", "arbiter@localhost"}
      ] ++ Keyword.get(opts, :env, [])

    cd = Keyword.get(opts, :cd) || System.tmp_dir!()

    case System.cmd("git", prefix ++ args, cd: cd, env: env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim_trailing(out)}
      {out, code} -> {:error, {:git, code, String.trim(out)}}
    end
  rescue
    e in ErlangError -> {:error, {:git, 127, Exception.message(e)}}
  end

  @doc "`run/2` returning the output, or raising on failure (for code that cannot recover)."
  @spec run!([String.t()], keyword()) :: String.t()
  def run!(args, opts \\ []) do
    case run(args, opts) do
      {:ok, out} -> out
      {:error, {:git, code, out}} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  @doc "Whether `rev` names an object in `git_dir`."
  @spec exists?(Path.t(), String.t()) :: boolean()
  def exists?(git_dir, rev), do: match?({:ok, _}, run(["cat-file", "-e", rev], git_dir: git_dir))

  @doc "The sha `rev` resolves to in `git_dir`, or `nil`."
  @spec rev_parse(Path.t(), String.t()) :: String.t() | nil
  def rev_parse(git_dir, rev) do
    case run(["rev-parse", "--verify", "-q", rev], git_dir: git_dir) do
      {:ok, sha} when sha != "" -> sha
      _ -> nil
    end
  end

  @doc "The absolute git dir of the repo or work tree at `path`."
  @spec git_dir(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def git_dir(path) do
    case run(["rev-parse", "--absolute-git-dir"], cd: path) do
      {:ok, dir} -> {:ok, dir}
      {:error, {:git, _, out}} -> {:error, {:not_a_repo, path, out}}
    end
  end

  defp dir_flag(_flag, nil), do: []
  defp dir_flag(flag, dir), do: [flag, to_string(dir)]
end
