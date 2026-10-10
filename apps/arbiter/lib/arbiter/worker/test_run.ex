defmodule Arbiter.Worker.TestRun do
  @moduledoc """
  Runs `mix test` for a worker in the run's own environment and returns the
  compact result (`Arbiter.Worker.TestReport`) instead of the raw ExUnit output
  (bd-57nhsi). The behind-the-scenes of the `run_tests` MCP tool.

  The worker's `mix test` output (compile chatter, passing dots, warnings) is
  re-read on every later turn of the session; this keeps it on disk and hands
  back only the counts and each failing test's header and assertion.

  A *runner* says where the command executes — the same `exec` seam the pre-push
  check uses (`Arbiter.Worker.PrepushCheck`): `fn command, timeout_s ->
  {output, status} | {:error, reason}` is `Arbiter.Worker.ContainerSpawn.run_command/3`
  for a local podman run, `Arbiter.Worker.Executor.Node.exec/4` for a run placed
  on a node (the node's agent runs it in a container of the run's shape), and a
  host `sh` for an unsandboxed run. Every command is a plain `sh -c` string, so
  the node path needs nothing more than the transport it already has.

  Selecting tests, in the order they are decided:

    * `paths` — test files (optionally `:line`) or directories. A path that
      exists at the repo root is taken as is; otherwise it is looked for under
      `apps/*/` (so `test/foo_test.exs` finds its umbrella app). A path that
      resolves nowhere is refused, never dropped: `mix test <missing path>` from
      an umbrella root runs the whole suite.
    * `changed` — the tests mapped from what the branch touched: committed
      changes since the merge base with the task's target branch, plus uncommitted
      and untracked files, mapped with `PrepushCheck.Touched` (a changed test is
      itself, a changed `lib/x.ex` is `test/x_test.exs` beside it).

  Umbrella paths are grouped by `apps/<app>/` and each group runs from its app's
  directory, as `scripts/pre-push-tests.sh` does. The whole output is written to
  `$TMPDIR/arb-test-*.log` inside the run's environment (its per-run temp
  directory) and the path is returned, so a worker that really needs the raw
  output can read it.
  """

  alias Arbiter.Worker.PrepushCheck.Touched
  alias Arbiter.Worker.TestReport

  @default_timeout_s 600
  @max_timeout_s 1800
  @probe_timeout_s 60
  @log_marker "ARB_TEST_LOG="

  @type runner :: %{
          required(:exec) => (String.t(), pos_integer() ->
                                {String.t(), integer()} | {:error, term()}),
          required(:worktree) => String.t(),
          optional(:target) => String.t() | nil
        }

  @type request :: %{
          optional(:paths) => [String.t()],
          optional(:changed) => boolean(),
          optional(:timeout_s) => pos_integer()
        }

  @type result :: %{
          report: TestReport.t(),
          text: String.t(),
          log_path: String.t() | nil,
          command: String.t()
        }

  @doc """
  Run the selected tests through `runner` and return the report, its rendered
  text and the full log's path. Blocks for the run: call it from the request
  process, never from the worker's GenServer.

  Options: `:mix` — the mix command (default `mix`); `:limit` — the report's
  character cap.
  """
  @spec run(runner(), request(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def run(%{exec: exec} = runner, request, opts \\ []) when is_function(exec, 2) do
    timeout_s = timeout(request)

    with {:ok, requested, strict?} <- requested(runner, request),
         {:ok, resolved} <- resolve(exec, requested, strict?) do
      case resolved do
        [] -> {:ok, nothing_to_run()}
        paths -> execute(exec, paths, timeout_s, opts)
      end
    end
  end

  defp timeout(%{timeout_s: n}) when is_integer(n) and n > 0, do: min(n, @max_timeout_s)
  defp timeout(_), do: @default_timeout_s

  defp nothing_to_run do
    %{
      report: TestReport.build("", 0),
      text: "no tests: nothing in the change maps to a test file; pass `paths` to choose some",
      log_path: nil,
      command: ""
    }
  end

  # -- selecting the paths ----------------------------------------------------

  defp requested(runner, %{changed: true} = request) do
    case Map.get(request, :paths, []) do
      [] -> changed_candidates(runner)
      _ -> {:error, "pass either `paths` or `changed`, not both"}
    end
  end

  defp requested(_runner, %{paths: [_ | _] = paths}) do
    with :ok <- validate_paths(paths), do: {:ok, paths, true}
  end

  defp requested(_runner, _request),
    do: {:error, "name what to run: `paths` (test files or directories) or `changed: true`"}

  defp validate_paths(paths) do
    case Enum.reject(paths, &safe_path?/1) do
      [] -> :ok
      bad -> {:error, "not a test path inside the repo: #{Enum.join(bad, ", ")}"}
    end
  end

  # `path`, `path:12`, `path:12:30`: repo-relative, no option-looking words, no
  # `..` segment, nothing the shell would act on.
  defp safe_path?(path) when is_binary(path) do
    Regex.match?(~r{\A[A-Za-z0-9_][A-Za-z0-9_./@-]*(:\d+)*\z}, path) and
      ".." not in String.split(path, "/")
  end

  defp safe_path?(_), do: false

  defp changed_candidates(%{exec: exec, target: target}) do
    if is_binary(target) and Regex.match?(~r{\A[A-Za-z0-9_][A-Za-z0-9_./-]*\z}, target) do
      case exec.(changed_files_command(target), @probe_timeout_s) do
        {out, 0} ->
          candidates =
            out
            |> String.split("\n", trim: true)
            |> Touched.candidate_test_files()
            |> Enum.sort()

          {:ok, candidates, false}

        {:error, reason} ->
          {:error,
           "could not ask the run's environment for the changed files: #{inspect(reason)}"}

        _ ->
          {:error, "could not work out the changed files against #{target}; pass `paths` instead"}
      end
    else
      {:error, "no target branch to diff against; pass `paths` instead of `changed`"}
    end
  end

  # Committed changes since the merge base, uncommitted ones, and new files.
  defp changed_files_command(target) do
    """
    base=$(git merge-base 'origin/#{target}' HEAD 2>/dev/null || git merge-base '#{target}' HEAD 2>/dev/null) || exit 3
    { git diff --name-only --diff-filter=ACMR "$base"; git ls-files --others --exclude-standard; } | sort -u
    """
  end

  # The path as it exists in the run's checkout: at the root, else under the
  # first `apps/*/` that has it. One probe covers them all.
  defp resolve(exec, requested, strict?) do
    case exec.(resolve_command(requested), @probe_timeout_s) do
      {out, 0} ->
        lines = String.split(out, "\n", trim: true)
        {found, missing} = Enum.split_with(lines, &(not String.starts_with?(&1, "?")))

        cond do
          strict? and missing != [] ->
            names = Enum.map_join(missing, ", ", &String.trim_leading(&1, "?"))
            {:error, "no such test path: #{names}"}

          true ->
            {:ok, Enum.uniq(found)}
        end

      {:error, reason} ->
        {:error, "could not run in the run's environment: #{inspect(reason)}"}

      {out, status} ->
        {:error, "path check exited #{status}: #{String.slice(out, 0, 300)}"}
    end
  end

  defp resolve_command(paths) do
    """
    for p in #{Touched.quote_args(paths)}; do
      f="${p%%:*}"
      if [ -e "$f" ]; then echo "$p"; continue; fi
      r=""
      for d in apps/*/; do
        if [ -e "$d$f" ]; then r="$d$p"; break; fi
      done
      if [ -n "$r" ]; then echo "$r"; else echo "?$p"; fi
    done
    """
  end

  # -- running them -----------------------------------------------------------

  defp execute(exec, paths, timeout_s, opts) do
    command = test_command(paths, Keyword.get(opts, :mix, "mix"))

    case exec.(command, timeout_s) do
      {:error, reason} ->
        {:error, "could not run the tests: #{inspect(reason)}"}

      {output, status} ->
        {log_path, output} = split_log_marker(output)
        report = TestReport.build(output, status, Keyword.take(opts, [:limit]))

        {:ok,
         %{report: report, text: TestReport.render(report), log_path: log_path, command: command}}
    end
  end

  @doc false
  @spec test_command([String.t()], String.t()) :: String.t()
  def test_command(paths, mix \\ "mix") do
    log = "arb-test-#{System.system_time(:second)}-#{System.unique_integer([:positive])}.log"

    runs =
      paths
      |> group()
      |> Enum.map_join("\n", fn
        {nil, files} ->
          "  #{mix} test #{Touched.quote_args(files)} || status=$?"

        {app, files} ->
          "  (cd 'apps/#{app}' && #{mix} test #{Touched.quote_args(files)}) || status=$?"
      end)

    """
    ELIXIR_ERL_OPTIONS="+fnu${ELIXIR_ERL_OPTIONS:+ $ELIXIR_ERL_OPTIONS}"; export ELIXIR_ERL_OPTIONS
    LOG="${TMPDIR:-/tmp}/#{log}"
    echo "#{@log_marker}$LOG"
    status=0
    {
    #{runs}
    } > "$LOG" 2>&1
    cat "$LOG"
    exit $status
    """
  end

  # `apps/<app>/rest` paths grouped per app (each runs from its own directory),
  # the rest at the root, in first-seen order.
  defp group(paths) do
    paths
    |> Enum.map(fn path ->
      case Regex.run(~r{\Aapps/([^/]+)/(.+)\z}, path) do
        [_, app, rest] -> {app, rest}
        nil -> {nil, path}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {app, _} -> Enum.find_index(paths, &group_of?(&1, app)) end)
  end

  defp group_of?(path, nil), do: not String.starts_with?(path, "apps/")
  defp group_of?(path, app), do: String.starts_with?(path, "apps/#{app}/")

  defp split_log_marker(output) do
    case String.split(output, "\n", parts: 2) do
      [@log_marker <> path, rest] -> {String.trim(path), rest}
      [@log_marker <> path] -> {String.trim(path), ""}
      _ -> {nil, output}
    end
  end
end
