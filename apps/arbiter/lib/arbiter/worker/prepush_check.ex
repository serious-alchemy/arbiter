defmodule Arbiter.Worker.PrepushCheck do
  @moduledoc """
  The per-repo pre-push check recipe (bd-28c6qo, GitHub #24; multi-step recipe
  bd-8wdrql, GitHub #662): the commands the worker commit gate runs before the
  branch is pushed or a PR is opened, so a lint-class failure (format, compile
  warning, credo, a broken doc citation, a test the change broke) bounces back
  to the same live worker session instead of costing a CI run and a cold fix pass.

  ## Config

  See `Arbiter.Worker.PrepushCheck.Recipe`. `worker.repos.<repo>` is deep-merged
  over the workspace-level `worker` block:

      {"worker": {
        "repos": {
          "arbiter": {"pre_push_checks": "arbiter"}
        }
      }}

  `pre_push_checks` is a list of `{name, cmd, timeout_s, scope}` steps (or the
  `"arbiter"` preset), bounded by `pre_push_budget_seconds` in total. The older
  single-command `prepush_check` (+ `_timeout_seconds`) is one step. Unset or
  blank at both levels means **no check and no behaviour change**.

  ## Outcomes (`run_steps/3`, `run/2`)

  Every step runs (a red format step does not hide a red credo step) unless the
  total budget runs out, in which case the rest are `:skipped`. The overall
  `result`:

    * all steps green or skipped for having nothing to check → `:ok`; the push proceeds.
    * a step exited non-zero → `{:failed, status, output}` (the first one); the
      worker commit gate sends every failed step's output back to the same
      session and nothing is pushed.
    * a step timed out, or the budget ran out → `{:timeout, output}`. A timeout
      says nothing about the code (a slow or contended host), so by default the
      gate **fails open** — it logs and lets the push go ahead, CI being the
      backstop. `on_timeout: :fail` treats it as a failure instead.
    * the checks could not be run at all (no worktree on disk, no `timeout`
      binary, a command `sh` could not exec → 126/127, the sandbox refused,
      spawn raised) → `{:error, reason}`; always fails open. A broken check
      must not strand work.

  `steps` is the per-step record (`t:step_result/0`) the worker writes to the
  run (`Arbiter.Workers.RunStep` rows) and `arb worker show` renders.

  ## Where it runs

  On the host, in the worktree, under coreutils `timeout` (SIGTERM to its whole
  process group, SIGKILL 10 s later, so `mix`/`dialyzer` descendants die with
  it), with the sanitised `Arbiter.Worker.SpawnEnv` environment (no server
  secrets, no inherited `MIX_ENV`) and a private per-run `TMPDIR`
  (`Arbiter.Worker.RunTmp`). A podman-sandboxed run passes `:exec` instead
  (`Arbiter.Worker.ContainerSpawn.run_command/3`): the same steps then run in
  the run's own container, with its mounts, home and no network.
  """

  alias Arbiter.Worker.PrepushCheck.Recipe
  alias Arbiter.Worker.PrepushCheck.Touched
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.RunTmp
  alias Arbiter.Worker.SpawnEnv

  @kill_after_seconds 10
  @max_output_bytes 16_000

  @type spec :: Recipe.spec() | map()

  @type result ::
          :ok
          | {:failed, non_neg_integer(), String.t()}
          | {:timeout, String.t()}
          | {:error, term()}

  @type step_result :: %{
          name: String.t(),
          cmd: String.t(),
          scope: Recipe.scope(),
          status: :passed | :failed | :timeout | :skipped | :error,
          exit_status: non_neg_integer() | nil,
          duration_ms: non_neg_integer(),
          limit_s: pos_integer() | nil,
          output: String.t(),
          reason: atom() | nil
        }

  @doc "The default `prepush_check_timeout_seconds` of the single-command form."
  @spec default_timeout_seconds() :: pos_integer()
  defdelegate default_timeout_seconds, to: Recipe, as: :default_legacy_timeout_seconds

  @doc """
  The recipe configured for `repo` in `workspace` (a `Workspace`, any
  config-bearing map, or `nil`), or `nil` when none is set.
  """
  @spec resolve(term(), String.t() | nil) :: spec() | nil
  defdelegate resolve(workspace, repo), to: Recipe

  @doc """
  Run the recipe in `worktree` and return only the overall result. Blocks for up
  to the budget (plus the kill grace) — call it from a task, not a GenServer callback.
  """
  @spec run(spec(), String.t()) :: result()
  def run(spec, worktree), do: run_steps(spec, worktree).result

  @doc """
  Run every step of `spec` in `worktree`, in order, within the spec's total budget.

  Options: `:target` — the branch the diff is taken against for `scope: touched`
  steps (the task's target branch); `:exec` — `fn command, timeout_s ->
  {output, status} | {:error, term}` to run each (already expanded) command in
  place of the host (the sandbox hook).
  """
  @spec run_steps(spec(), String.t(), keyword()) :: %{result: result(), steps: [step_result()]}
  def run_steps(spec, worktree, opts \\ []) when is_binary(worktree) do
    with :ok <- check_worktree(worktree),
         {:ok, exec, cleanup} <- executor(worktree, opts) do
      try do
        run_all(spec, worktree, exec, opts)
      after
        cleanup.()
      end
    else
      {:error, _} = err -> %{result: err, steps: []}
    end
  rescue
    e -> %{result: {:error, {:spawn_failed, Exception.message(e)}}, steps: []}
  end

  defp check_worktree(worktree) do
    if File.dir?(worktree), do: :ok, else: {:error, {:no_worktree, worktree}}
  end

  defp executor(worktree, opts) do
    case Keyword.get(opts, :exec) do
      fun when is_function(fun, 2) -> {:ok, fun, fn -> :ok end}
      _ -> host_executor(worktree)
    end
  end

  defp host_executor(worktree) do
    case System.find_executable("timeout") do
      nil ->
        {:error, :no_timeout_binary}

      timeout_bin ->
        tmp =
          case RunTmp.create("prepush") do
            {:ok, dir} -> dir
            {:error, _} -> nil
          end

        env = SpawnEnv.cmd_env(RunTmp.env_pairs(tmp), nil)

        exec = fn command, seconds ->
          args = [
            "--kill-after=#{@kill_after_seconds}",
            Integer.to_string(seconds),
            "sh",
            "-c",
            command
          ]

          ReleaseEnv.cmd(timeout_bin, args, cd: worktree, env: env, stderr_to_stdout: true)
        end

        {:ok, exec, fn -> RunTmp.remove(tmp) end}
    end
  end

  defp run_all(spec, worktree, exec, opts) do
    steps = steps_of(spec)
    budget = Map.get(spec, :budget_seconds) || spec.timeout_seconds
    deadline = System.monotonic_time(:millisecond) + budget * 1000
    touched = touched_for(steps, worktree, Keyword.get(opts, :target))

    results = Enum.map(steps, &run_step(&1, worktree, touched, deadline, exec))
    %{result: overall(results), steps: results}
  end

  # A spec built outside `Recipe` (the legacy shape) is one step.
  defp steps_of(%{steps: [_ | _] = steps}), do: steps

  defp steps_of(%{command: command, timeout_seconds: seconds}),
    do: [%{name: "prepush_check", cmd: command, timeout_s: seconds, scope: :all}]

  defp touched_for(steps, worktree, target) do
    if Enum.any?(steps, &(&1.scope == :touched)), do: Touched.files(worktree, target), else: :none
  end

  defp run_step(step, worktree, touched, deadline, exec) do
    started = System.monotonic_time(:millisecond)
    remaining = div(deadline - started + 999, 1000)

    limit = min(step.timeout_s, max(remaining, 0))

    outcome =
      if remaining <= 0 do
        {:skipped, :budget, "skipped: the total time budget was already spent"}
      else
        expand_and_run(step, worktree, touched, limit, exec)
      end

    record(step, outcome, System.monotonic_time(:millisecond) - started, limit)
  end

  defp expand_and_run(step, worktree, touched, seconds, exec) do
    case expand(step, worktree, touched) do
      :nothing_touched ->
        {:skipped, :untouched, "skipped: no touched files for this step"}

      {:ok, command} ->
        command |> safe_exec(exec, seconds) |> classify()
    end
  end

  defp safe_exec(command, exec, seconds) do
    exec.(command, seconds)
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  @placeholders [
    {"{files}", :all_files},
    {"{elixir_files}", :elixir_files},
    {"{credo_files}", :credo_files},
    {"{test_files}", :test_files}
  ]

  defp expand(%{scope: :touched, cmd: cmd}, worktree, touched) do
    present = for {token, kind} <- @placeholders, String.contains?(cmd, token), do: {token, kind}

    case {present, touched} do
      {[], _} ->
        {:ok, cmd}

      {_, {:ok, files}} ->
        replaced = for {token, kind} <- present, do: {token, files_for(kind, files, worktree)}

        if Enum.any?(replaced, fn {_, list} -> list == [] end) do
          :nothing_touched
        else
          {:ok,
           Enum.reduce(replaced, cmd, fn {t, list}, acc ->
             String.replace(acc, t, Touched.quote_args(list))
           end)}
        end

      # The diff base could not be resolved: run the command over everything
      # (the placeholder simply drops out) rather than silently skipping it.
      {_, _} ->
        {:ok, Enum.reduce(present, cmd, fn {token, _}, acc -> String.replace(acc, token, "") end)}
    end
  end

  defp expand(%{cmd: cmd}, _worktree, _touched), do: {:ok, cmd}

  defp files_for(:all_files, files, _worktree), do: files
  defp files_for(:elixir_files, files, _worktree), do: Touched.elixir_files(files)
  defp files_for(:credo_files, files, _worktree), do: Touched.credo_files(files)
  defp files_for(:test_files, files, worktree), do: Touched.test_files(files, worktree)

  # coreutils `timeout`: 124 = the command timed out, 137 = it needed the
  # SIGKILL; 126/127 = `sh` could not exec the command itself.
  defp classify({:error, reason}), do: {:error, reason, ""}
  defp classify({_output, 0}), do: {:passed, 0, ""}
  defp classify({output, status}) when status in [124, 137], do: {:timeout, status, tail(output)}

  defp classify({output, status}) when status in [126, 127],
    do: {:error, {:not_runnable, status, tail(output)}, tail(output)}

  defp classify({output, status}) do
    case infra_signature(output) do
      nil -> {:failed, status, tail(output)}
      label -> {:infra, label, tail(output)}
    end
  end

  # A non-zero exit whose output says the *environment* is broken, not the code:
  # the deps were never fetched (the run's checkout is not the worker's seeded
  # one), a tool is missing from the image, or the container did not start. It
  # must never be sent to the worker as a code failure, so it is recorded as
  # `skipped: infra` and the gate fails open (bd-9rrrgk). Matched on the output
  # of a failing step only, and on phrases a code failure does not print.
  @infra_signatures [
    {"dependencies are not available (mix deps.get)",
     ~r/the dependency is not available|Unchecked dependencies for environment|Can't continue due to errors on dependencies|dependency [\w:]+ is not available|run [`"']?mix deps\.get/i},
    {"deps missing for the formatter's import_deps",
     ~r/Unknown dependency :\w+ given to :import_deps/},
    {"tool not found in the image",
     ~r/(^|\n)(sh: (\d+: )?)?(mix|elixir|erl|node|npm|cargo|git|make): (command )?not found|executable file `[^`]+` not found in \$PATH/},
    {"container could not start",
     ~r/Cannot connect to Podman|(^|\n)Error: (crun|runc|creating container|.*image (is )?not known|.*no such image|.*unable to (start|find) |.*OCI runtime)|podman: command not found/i}
  ]

  defp infra_signature(output) when is_binary(output) do
    Enum.find_value(@infra_signatures, fn {label, re} ->
      if Regex.match?(re, output), do: label
    end)
  end

  defp record(step, outcome, duration_ms, limit) do
    {status, exit_status, reason, output} =
      case outcome do
        {:skipped, why, note} -> {:skipped, nil, why, note}
        {:error, why, out} -> {:error, nil, why, out}
        {:infra, label, out} -> {:skipped, nil, :infra, infra_output(label, out)}
        {status, code, out} -> {status, code, nil, out}
      end

    %{
      name: step.name,
      cmd: step.cmd,
      scope: step.scope,
      status: status,
      exit_status: exit_status,
      duration_ms: max(duration_ms, 0),
      limit_s: if(limit > 0, do: limit),
      output: output,
      reason: reason
    }
  end

  defp overall(results) do
    cond do
      failed = Enum.find(results, &(&1.status == :failed)) ->
        {:failed, failed.exit_status, failed.output}

      timed_out = Enum.find(results, &(&1.status == :timeout or budget_skip?(&1))) ->
        {:timeout, timed_out.output}

      infra = Enum.find(results, &infra_skip?/1) ->
        {:error, {:infra, infra.name, infra_label(infra.output)}}

      errored = Enum.find(results, &(&1.status == :error)) ->
        {:error, errored.reason}

      true ->
        :ok
    end
  end

  defp budget_skip?(%{status: :skipped, reason: :budget}), do: true
  defp budget_skip?(_), do: false

  defp infra_skip?(%{status: :skipped, reason: :infra}), do: true
  defp infra_skip?(_), do: false

  defp infra_output(label, out), do: "skipped: infra (#{label})\n" <> out

  defp infra_label(output) do
    case Regex.run(~r/\Askipped: infra \((.*)\)/, output) do
      [_, label] -> label
      _ -> "infrastructure"
    end
  end

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

    #{check_section(meta, detail, @max_output_bytes)}

    Do EXACTLY this, then print `arb done` again on its own line:

      1. Fix what the output reports. Do not delete or weaken the check, and
         do not skip it with flags — change the code.
      2. Re-run the failing command(s) above yourself until they exit 0.
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

    "the pre-push check (`worker.pre_push_checks`) is red on branch `#{branch}`, so the " <>
      "branch was NOT pushed.\n\n" <> check_section(meta, detail, @summary_output_bytes)
  end

  # The "what failed" block. With per-step results (a recipe run) it names each
  # failed step with its own bounded output and lists the whole recipe for a
  # manual re-run; without them (the legacy single command) it is the one command.
  defp check_section(meta, detail, max) do
    case failed_steps(meta) do
      [] -> single_section(meta, detail, max)
      failed -> steps_section(meta, failed, max)
    end
  end

  defp single_section(meta, detail, max) do
    "Check command (run from the repo root of your worktree):\n\n" <>
      "    #{command(meta)}\n\n" <>
      "#{what_happened(detail)}\n\nOutput (last lines):\n\n" <> indent(output(detail, max))
  end

  defp steps_section(meta, failed, max) do
    per_step = div(max, length(failed))

    blocks =
      Enum.map_join(failed, "\n\n", fn step ->
        "Step `#{step.name}` (`#{step.cmd}`): #{step_what_happened(step)}\n\n" <>
          "Output (last lines):\n\n" <> indent(tail(step.output, per_step))
      end)

    "Pre-push recipe, run from the repo root of your worktree (a step marked `touched` " <>
      "only sees the files your branch changed):\n\n" <>
      recipe_list(meta) <> "\n\n" <> blocks
  end

  defp recipe_list(meta) do
    steps = Map.get(meta, :prepush_steps) || []
    Enum.map_join(steps, "\n", &"    #{&1.name}: #{&1.cmd}")
  end

  defp failed_steps(meta) do
    (Map.get(meta, :prepush_steps) || [])
    |> Enum.filter(&(&1.status in [:failed, :timeout]))
  end

  defp step_what_happened(%{status: :failed, exit_status: status}),
    do: "exited with status #{status}."

  defp step_what_happened(%{status: :timeout} = step),
    do:
      "timed out after #{step.limit_s}s and was killed (this workspace treats a timeout as a failure: " <>
        "`worker.prepush_check_on_timeout` is \"fail\")."

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

  defp output({_, _, text}, max) when is_binary(text), do: tail(text, max)
  defp output(_, _max), do: "(no output)"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
