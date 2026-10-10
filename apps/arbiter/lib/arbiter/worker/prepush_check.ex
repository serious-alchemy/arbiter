defmodule Arbiter.Worker.PrepushCheck do
  @moduledoc """
  The per-repo pre-push check (bd-28c6qo, GitHub #24): a command the worker
  commit gate runs in the worker's checkout before the branch is pushed or a
  PR is opened, so a lint-class failure (format, credo, dialyzer, …) bounces
  back to the same worker session instead of costing a CI run and a fix pass.

  ## Config

  Resolved like `worker.repos.<repo>.seed_paths` (`Arbiter.Worker.SeedPaths`):
  `worker.repos.<repo>` is deep-merged over the workspace-level `worker` block.

      {"worker": {
        "prepush_check": "make lint",
        "prepush_check_timeout_seconds": 1200,
        "repos": {
          "arbiter": {"prepush_check": "mix precommit && mix audit"}
        }
      }}

    * `prepush_check` — a shell command (`sh -c`), run in the worktree. Unset
      or blank at both levels means **no check and no behaviour change**.
    * `prepush_check_timeout_seconds` — positive integer, default
      1200. Size it for the slowest step: dialyzer with a cold PLT takes
      ~7 minutes on its own (seed `priv/plts` via `worker.repos.<repo>.seed_paths`
      to avoid that).
    * `prepush_check_on_timeout` — `"proceed"` (default) or `"fail"`.

  ## Outcomes (`run/2`)

    * exit 0 → `:ok`; the push proceeds.
    * non-zero exit → `{:failed, status, output}`; the worker commit gate sends
      `output` back to the same session and nothing is pushed.
    * timed out → `{:timeout, output}`. A timeout says nothing about the code
      (a slow or contended host), so by default the gate **fails open** — it logs
      and lets the push go ahead, CI being the backstop — mirroring
      `Arbiter.Agents.Preflight`'s timeout. `on_timeout: :fail` treats it as a
      failure instead.
    * the check could not be run at all (no worktree on disk, no `timeout`
      binary, `sh` could not exec the command → 126/127, spawn raised) →
      `{:error, reason}`; always fails open. A broken check must not strand work.

  The command runs under coreutils `timeout` (SIGTERM to its whole process
  group, SIGKILL 10 s later), so descendants like `mix`/`dialyzer` die with it.
  It gets the sanitised `Arbiter.Worker.SpawnEnv` environment (no server
  secrets, no inherited `MIX_ENV`) and a private per-run `TMPDIR`
  (`Arbiter.Worker.RunTmp`), removed afterwards.
  """

  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.RunTmp
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.SpawnEnv

  @default_timeout_seconds 1200
  @kill_after_seconds 10
  @max_output_bytes 16_000

  @type spec :: %{
          command: String.t(),
          timeout_seconds: pos_integer(),
          on_timeout: :proceed | :fail
        }

  @type result ::
          :ok
          | {:failed, non_neg_integer(), String.t()}
          | {:timeout, String.t()}
          | {:error, term()}

  @doc "The default `prepush_check_timeout_seconds`."
  @spec default_timeout_seconds() :: pos_integer()
  def default_timeout_seconds, do: @default_timeout_seconds

  @doc """
  The check configured for `repo` in `workspace` (a `Workspace`, any
  config-bearing map, or `nil`), or `nil` when none is set.
  """
  @spec resolve(term(), String.t() | nil) :: spec() | nil
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    effective = SeedPaths.effective(worker, repo)

    case effective do
      %{"prepush_check" => command} when is_binary(command) ->
        build_spec(String.trim(command), effective)

      _ ->
        nil
    end
  end

  def resolve(_workspace, _repo), do: nil

  defp build_spec("", _effective), do: nil

  defp build_spec(command, effective) do
    %{
      command: command,
      timeout_seconds: timeout_seconds(Map.get(effective, "prepush_check_timeout_seconds")),
      on_timeout: on_timeout(Map.get(effective, "prepush_check_on_timeout"))
    }
  end

  defp timeout_seconds(n) when is_integer(n) and n > 0, do: n
  defp timeout_seconds(_), do: @default_timeout_seconds

  defp on_timeout("fail"), do: :fail
  defp on_timeout(_), do: :proceed

  @doc """
  Run the check in `worktree`. Blocks for up to `timeout_seconds` (plus the
  kill grace) — call it from a task, not a GenServer callback.
  """
  @spec run(spec(), String.t()) :: result()
  def run(%{command: command, timeout_seconds: seconds}, worktree) when is_binary(worktree) do
    with :ok <- check_worktree(worktree),
         {:ok, timeout_bin} <- find_timeout() do
      run_in_tmp(timeout_bin, command, seconds, worktree)
    end
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp check_worktree(worktree) do
    if File.dir?(worktree), do: :ok, else: {:error, {:no_worktree, worktree}}
  end

  defp find_timeout do
    case System.find_executable("timeout") do
      nil -> {:error, :no_timeout_binary}
      path -> {:ok, path}
    end
  end

  defp run_in_tmp(timeout_bin, command, seconds, worktree) do
    tmp =
      case RunTmp.create("prepush") do
        {:ok, dir} -> dir
        {:error, _} -> nil
      end

    try do
      args = [
        "--kill-after=#{@kill_after_seconds}",
        Integer.to_string(seconds),
        "sh",
        "-c",
        command
      ]

      env = SpawnEnv.cmd_env(RunTmp.env_pairs(tmp), nil)

      timeout_bin
      |> ReleaseEnv.cmd(args, cd: worktree, env: env, stderr_to_stdout: true)
      |> classify()
    after
      RunTmp.remove(tmp)
    end
  end

  # coreutils `timeout`: 124 = the command timed out, 137 = it needed the
  # SIGKILL; 126/127 = `sh` could not exec the command itself.
  defp classify({_output, 0}), do: :ok
  defp classify({output, status}) when status in [124, 137], do: {:timeout, tail(output)}

  defp classify({output, status}) when status in [126, 127],
    do: {:error, {:not_runnable, status, tail(output)}}

  defp classify({output, status}), do: {:failed, status, tail(output)}

  @doc """
  The last `max` bytes of `text`, cut on a line boundary and prefixed with a
  truncation marker when anything was dropped.
  """
  @spec tail(String.t(), pos_integer()) :: String.t()
  def tail(text, max \\ @max_output_bytes) when is_binary(text) do
    text = String.trim_trailing(text)
    size = byte_size(text)

    if size <= max do
      text
    else
      kept = binary_part(text, size - max, max)

      kept =
        case :binary.split(kept, "\n") do
          [_partial, rest] -> rest
          [only] -> only
        end

      "[… output truncated to its last #{byte_size(kept)} bytes …]\n" <> kept
    end
  end

  @typedoc "A red check as the worker records it in `meta[:prepush_detail]`."
  @type detail ::
          {:exit, non_neg_integer(), String.t()} | {:timeout, pos_integer(), String.t()}

  @summary_output_bytes 4_000

  @doc """
  The prompt a failed check is sent back to the worker session with.
  `meta` is the worker's meta (for `:branch` and the stashed `:prepush_spec`).
  `ctx` distinguishes a main/fix-round run (`:main`) from a CI fix pass (`:fix_pass`).
  """
  @spec nudge_prompt(String.t(), map(), detail(), atom()) :: String.t()
  def nudge_prompt(task_id, meta, detail, ctx \\ :main) do
    branch = Map.get(meta, :branch) || Map.get(meta, :fix_pass_branch) || "(your branch)"

    intro =
      case ctx do
        :fix_pass ->
          "bd-28c6qo pre-push check: you printed `arb done` for task #{task_id}, but\n" <>
            "this repo's pre-push check is not green on branch `#{branch}`, so nothing\n" <>
            "has been pushed. CI runs the same checks and would fail the same way,\n" <>
            "so fix it now."

        _ ->
          "bd-28c6qo pre-push check: you printed `arb done` for task #{task_id}, but\n" <>
            "this repo's pre-push check is not green on branch `#{branch}`, so nothing\n" <>
            "has been pushed and no PR has been opened. CI runs the same checks and\n" <>
            "would fail the same way, so fix it now."
      end

    step_3 =
      case ctx do
        :fix_pass ->
          "`git add -A && git commit -m \"<a short message>\"` (the arbiter pushes to `#{branch}` for you)."

        _ ->
          "`git add -A && git commit -m \"<a short message>\"` (the arbiter pushes and opens the PR for you)."
      end

    """
    #{intro}

    Check command (run from the repo root of your worktree):

        #{command(meta)}

    #{what_happened(detail)}

    Output (last lines):

    #{indent(output(detail))}

    Do EXACTLY this, then print `arb done` again on its own line:

      1. Fix what the output reports. Do not delete or weaken the check, and
         do not skip it with flags — change the code.
      2. Re-run the check command above yourself until it exits 0.
      3. #{step_3}
    """
  end

  @doc """
  The reason paragraph for the escalation / notes written when the send-back
  budget is spent. `meta` carries `:prepush_spec` and `:prepush_detail`.
  """
  @spec failure_blurb(map()) :: String.t()
  def failure_blurb(meta) do
    detail = Map.get(meta, :prepush_detail)
    branch = Map.get(meta, :branch) || Map.get(meta, :fix_pass_branch) || "(unknown)"

    "the pre-push check (`worker.prepush_check`) is red on branch `#{branch}`, so the " <>
      "branch was NOT pushed.\n\nCommand: #{command(meta)}\n" <>
      "#{what_happened(detail)}\n\nOutput (last lines):\n" <>
      indent(output(detail, @summary_output_bytes))
  end

  defp command(meta) do
    case Map.get(meta, :prepush_spec) do
      %{command: command} -> command
      _ -> "(unknown)"
    end
  end

  defp what_happened({:exit, status, _output}), do: "It exited with status #{status}."

  defp what_happened({:timeout, seconds, _output}),
    do:
      "It timed out after #{seconds}s and was killed (this workspace treats a timeout as a " <>
        "failure: `worker.prepush_check_on_timeout` is \"fail\")."

  defp what_happened(_), do: "It did not pass."

  defp output(detail, max \\ @max_output_bytes)
  defp output({_, _, text}, max) when is_binary(text), do: tail(text, max)
  defp output(_, _max), do: "(no output)"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
