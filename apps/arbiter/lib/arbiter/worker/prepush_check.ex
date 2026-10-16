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
      the node could not be asked, spawn raised) → `{:error, reason}`; always
      fails open. A broken check must not strand work.
    * a step exited non-zero but its output says the *environment* is broken, not
      the code (the deps were never fetched, the tool is not in the image, the
      container did not start; `infra_signature/2`) → the step is `:skipped` with
      reason `:infra` and an output starting `skipped: infra (…)`, and the result
      is `{:error, {:infra, step_name, label}}`: it fails open like any other
      error, is never sent to the worker as a code failure, and so never uses one
      of its attempts (bd-9rrrgk). A real failure in another step still wins.

  `steps` is the per-step record (`t:step_result/0`) the worker writes to the
  run (`Arbiter.Workers.RunStep` rows) and `arb worker show` renders.

  ## Offline, with no per-run proxy (bd-9xcogk)

  The gate never has egress of its own to rely on. A container run (local or on a node)
  gets no egress bridge and none of the agent's `HTTP(S)_PROXY`/`ALL_PROXY`/`NO_PROXY`
  (`Arbiter.Worker.GateEnv`); a host run has loopback proxies of the server's environment
  unset. The deps and `_build` (with test-only NIFs such as `lazy_html`) must already be in
  the worktree, and a copied `_build` must point at *this* worktree: before the first step
  the gate re-points its absolute `priv`/`include` links at the worktree's own `deps/`
  (`Arbiter.Worker.DepsRelocate.relink/1`), so a NIF an earlier seed reached through a
  directory that is gone (or is the source checkout) is found, and Mix has no reason to
  rebuild the dependency offline. Seeding does the same plus the manifests
  (`Worktree.seed_compiled_deps/3`, `DepsCache.install/3`). A run on a node is seeded
  the same way from the node's own deps cache (`DepsCache.seed_checkout/3`, called by
  `Arbiter.NodeAgent.Run`; bd-4uom27), every dependency compiled for the lockfile with
  no list of libraries. When the deps are still not there, the failure is infra, and the
  steps after the first one that hit it are skipped unrun. Any dependency that could not
  be fetched or built counts, whatever the library: `Error happened while installing …
  from precompiled binary`, `Error while downloading precompiled NIF`, `Could not compile
  with "make"`, a failed fetch while building a dependency, and Mix's `could not compile
  dependency :name`, except for a sibling app of an umbrella (`apps/<name>`), whose
  compile error is the change's own.

  ## Where it runs

  On the host, in the worktree, under coreutils `timeout` (SIGTERM to its whole
  process group, SIGKILL 10 s later, so `mix`/`dialyzer` descendants die with
  it), with the sanitised `Arbiter.Worker.SpawnEnv` environment (no server
  secrets, no inherited `MIX_ENV`) and a private per-run `TMPDIR`
  (`Arbiter.Worker.RunTmp`). A podman-sandboxed run passes `:exec` instead
  (`Arbiter.Worker.ContainerSpawn.run_command/3`): the same steps then run in
  the run's own container, with its mounts, home and no network. A run placed on a
  node passes the node's `:exec` (`Arbiter.Worker.Executor.Node.exec/4`): the
  steps then run in a container the node's agent builds from the run's spec
  (`Arbiter.NodeAgent.Exec`), where its image and deps are; the primary's copy of
  the worktree has neither (bd-9rrrgk).
  """

  alias Arbiter.Worker.DepsRelocate
  alias Arbiter.Worker.GateEnv
  alias Arbiter.Worker.PrepushCheck.Recipe
  alias Arbiter.Worker.PrepushCheck.Touched
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.RunTmp
  alias Arbiter.Worker.SpawnEnv

  @kill_after_seconds 10
  @max_output_bytes 16_000
  @offline_deps_label "could not fetch or build a dependency (the gate has no network)"

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
          full_output: String.t() | nil,
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
         :ok <- DepsRelocate.relink(worktree),
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

        env = SpawnEnv.cmd_env(RunTmp.env_pairs(tmp) ++ GateEnv.host_unsets(), nil)

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

    results = run_each(steps, worktree, touched, deadline, exec)
    %{result: overall(results), steps: results}
  end

  # In order. A step that found a dependency it cannot fetch or build in the gate
  # (no network) says the same of every later step, each of which would burn its
  # timeout retrying: they are recorded as skipped infra without running.
  defp run_each(steps, worktree, touched, deadline, exec) do
    {results, _halt} =
      Enum.map_reduce(steps, nil, fn
        step, nil ->
          result = run_step(step, worktree, touched, deadline, exec)
          {result, offline_deps_halt(result)}

        step, label ->
          {not_run(step, label), label}
      end)

    results
  end

  defp offline_deps_halt(%{status: :skipped, reason: :infra, output: output}) do
    label = infra_label(output)
    if label == @offline_deps_label, do: label
  end

  defp offline_deps_halt(_), do: nil

  defp not_run(step, label) do
    record(
      step,
      {:infra, label, "not run: an earlier step could not fetch or build a dependency"},
      0,
      0
    )
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

    {outcome, full} =
      if remaining <= 0 do
        {{:skipped, :budget, "skipped: the total time budget was already spent"}, nil}
      else
        expand_and_run(step, worktree, touched, limit, exec)
      end

    record(step, outcome, System.monotonic_time(:millisecond) - started, limit, full)
  end

  defp expand_and_run(step, worktree, touched, seconds, exec) do
    case expand(step, worktree, touched) do
      :nothing_touched ->
        {{:skipped, :untouched, "skipped: no touched files for this step"}, nil}

      {:ok, command} ->
        raw = safe_exec(command, exec, seconds)
        {classify(raw, worktree), full_output(raw)}
    end
  end

  defp full_output({output, _status}) when is_binary(output), do: output
  defp full_output(_), do: nil

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
  defp classify({:error, reason}, _worktree),
    do: {:error, reason, "the check could not be run: " <> inspect(reason, limit: 10)}

  defp classify({_output, 0}, _worktree), do: {:passed, 0, ""}

  defp classify({output, status}, _worktree) when status in [124, 137],
    do: {:timeout, status, tail(output)}

  defp classify({output, status}, _worktree) when status in [126, 127],
    do: {:error, {:not_runnable, status, tail(output)}, tail(output)}

  defp classify({output, status}, worktree) do
    case infra_signature(output, worktree) do
      nil -> {:failed, status, digest(output)}
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
    {@offline_deps_label, :offline_deps},
    {"dependencies are not available (mix deps.get)",
     ~r/the dependency is not available|Unchecked dependencies for environment|Can't continue due to errors on dependencies|dependency [\w:]+ is not available|run [`"']?mix deps\.get/i},
    {"deps missing for the formatter's import_deps",
     ~r/Unknown dependency :\w+ given to :import_deps/},
    {"tool not found in the image",
     ~r/(^|\n)(sh: (\d+: )?)?(mix|elixir|erl|node|npm|cargo|git|make): (command )?not found|executable file `[^`]+` not found in \$PATH/},
    {"container could not start",
     ~r/Cannot connect to Podman|(^|\n)Error: (crun|runc|creating container|.*image (is )?not known|.*no such image|.*unable to (start|find) |.*OCI runtime)|podman: command not found/i}
  ]

  defp infra_signature(output, worktree) when is_binary(output) do
    Enum.find_value(@infra_signatures, fn {label, matcher} ->
      if signature_match?(matcher, output, worktree), do: label
    end)
  end

  defp signature_match?(:offline_deps, output, worktree), do: offline_deps?(output, worktree)
  defp signature_match?(re, output, _worktree), do: Regex.match?(re, output)

  # A dependency the gate could not fetch or build (it has no network). The first
  # phrases only Mix, elixir_make and rustler_precompiled print (any NIF library:
  # `Error while downloading precompiled NIF`, bd-4uom27). The bare network errors (git, curl) are
  # not specific to it, so they count only beside Mix's own report that it was
  # fetching or compiling a dependency, and never in the output of a test run that
  # got far enough to print an ExUnit failure summary: a failing test that prints
  # captured git stderr is a code failure.
  @offline_deps_strong ~r/Error happened while installing \S+ from precompiled binary|Could not compile with "make"|Could not (install|find) Hex|[Pp]recompiled NIF/
  @offline_deps_network ~r/unable to access 'https?:|Failed to connect to \S+ port \d+|Could not resolve host|Failed to fetch record for/
  @mix_dep_context ~r/\*\* \(Mix\)|\belixir_make\b|==> \w+\nCompiling|Failed to fetch|mix deps\.(get|compile)/
  @exunit_failures ~r/\b\d+ tests?, [1-9]\d* failures?/

  # Mix's report that a dependency would not build. It is printed before the project's
  # own code is compiled, so it is the environment's doing, not the change's, except
  # for an umbrella sibling (`apps/<name>` in the worktree), which Mix also builds as a
  # dependency of the app under test: a compile error there is the change's own.
  @dep_compile_failed ~r/could not compile dependency :(\w+)/

  defp offline_deps?(output, worktree) do
    cond do
      # A test run that got far enough to print a failure summary compiled everything
      # first: whatever it quotes of Mix or a NIF is test output, a code failure.
      Regex.match?(@exunit_failures, output) ->
        false

      Regex.match?(@offline_deps_strong, output) ->
        true

      third_party_dep_failed?(output, worktree) ->
        true

      true ->
        Regex.match?(@offline_deps_network, output) and Regex.match?(@mix_dep_context, output)
    end
  end

  defp third_party_dep_failed?(output, worktree) do
    @dep_compile_failed
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.any?(fn [name] -> not own_app?(worktree, name) end)
  end

  defp own_app?(worktree, name), do: File.dir?(Path.join([worktree, "apps", name]))

  defp record(step, outcome, duration_ms, limit, full \\ nil) do
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
      full_output: full,
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

  @failures_header "ExUnit failures:\n"
  @tail_separator "\n\n--- output tail ---\n"
  @max_failure_block_bytes 1_500
  @max_failures_bytes 6_000

  @doc """
  What a failed step stores. When the output carries ExUnit's numbered `N) test …`
  failure blocks they come first (each capped, the section capped), then the
  `N tests, M failures` summary and `Result:` lines, then the generic tail. The
  blocks are printed before the summary, so the tail alone loses them whenever a
  sandbox-kill report or crash dump follows (bd-8e8t72). Any other output is the
  plain `tail/2`, as is any output that already fits.
  """
  @spec digest(String.t()) :: String.t()
  def digest(output) when is_binary(output) and byte_size(output) <= @max_output_bytes,
    do: tail(output)

  def digest(output) when is_binary(output) do
    case failure_section(output) do
      nil ->
        tail(output)

      section ->
        section <> @tail_separator <> tail(output, @max_output_bytes - byte_size(section))
    end
  end

  @doc """
  `text` bounded to `max` bytes. A `digest/1` keeps its failure section whole
  and trims only the tail behind it; other text is `tail/2`.
  """
  @spec fit(String.t(), pos_integer()) :: String.t()
  def fit(text, max) when is_binary(text) do
    with @failures_header <> _ <- text,
         [section, rest] <- String.split(text, @tail_separator, parts: 2) do
      section = cap(section, max)
      room = max - byte_size(section)
      if room > 200, do: section <> @tail_separator <> tail(rest, room), else: section
    else
      _ -> tail(text, max)
    end
  end

  defp cap(text, max) when byte_size(text) <= max, do: text
  defp cap(text, max), do: binary_part(text, 0, max) <> "\n[… truncated …]"

  defp failure_section(output) do
    with [{from, _}] <- Regex.run(~r/^[ \t]+1\) /m, output, return: :index),
         blocks when blocks != [] <-
           failure_blocks(binary_part(output, from, byte_size(output) - from)) do
      summary =
        ~r/^(?:(?:\d+ (?:doctests?|properties), )*\d+ tests?, \d+ failures?.*|Result:.*)$/m
        |> Regex.scan(output)
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      body = Enum.map_join(blocks, "\n", &cap(&1, @max_failure_block_bytes))

      cap(@failures_header <> body, @max_failures_bytes) <>
        if(summary == [], do: "", else: "\n" <> Enum.join(summary, "\n"))
    else
      _ -> nil
    end
  end

  # From the first numbered block to ExUnit's `Finished in` line (or the end),
  # split at each `  N) ` header.
  defp failure_blocks(from_first) do
    body = from_first |> String.split(~r/^Finished in /m, parts: 2) |> hd()

    body
    |> String.split(~r/\n(?=\s+\d+\) )/)
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.filter(&Regex.match?(~r/\A\s+\d+\) /, &1))
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
    #{tests_hint_block(meta)}

    Do EXACTLY this, then print `arb done` again on its own line:

      1. Fix what the output reports. Do not delete or weaken the check, and
         do not skip it with flags — change the code.
      2. Re-run the failing command(s) above yourself until they exit 0.
      3. #{step_3}
    """
  end

  defp tests_hint_block(meta) do
    case Touched.tests_hint(Map.get(meta, :worktree_path), Map.get(meta, :target_branch)) do
      "" -> ""
      hint -> "\n" <> hint <> "\n"
    end
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
          "Output (last lines):\n\n" <> indent(fit(step.output, per_step))
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

  defp output({_, _, text}, max) when is_binary(text), do: fit(text, max)
  defp output(_, _max), do: "(no output)"

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
