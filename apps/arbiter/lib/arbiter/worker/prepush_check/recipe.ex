defmodule Arbiter.Worker.PrepushCheck.Recipe do
  @moduledoc """
  The pre-push check recipe (bd-8wdrql): the ordered steps a worker run's commit
  gate executes before the branch is pushed, resolved from the workspace config.

  `worker.repos.<repo>` is deep-merged over the workspace-level `worker` block
  (`Arbiter.Worker.SeedPaths.effective/2`), then:

      {"worker": {
        "pre_push_budget_seconds": 180,
        "pre_push_max_attempts": 2,
        "repos": {
          "arbiter": {"pre_push_checks": "arbiter"},
          "other":   {"pre_push_checks": [
            {"name": "format", "cmd": "mix format --check-formatted", "timeout_s": 60},
            {"name": "credo", "cmd": "mix credo --strict {elixir_files}", "scope": "touched"}
          ]}
        }
      }}

    * `pre_push_checks` — a list of steps, or the string `"arbiter"` for
      `arbiter_preset/0`. A step is `{name, cmd, timeout_s, scope}`:
      `cmd` runs under `sh -c` in the worktree root; `timeout_s` defaults to
      #{120}; `scope` is `"all"` (default) or `"touched"`. A `touched` step
      may use `{files}`, `{elixir_files}` and `{test_files}` in `cmd`
      (see `Arbiter.Worker.PrepushCheck.Touched`): each expands to the branch's
      changed files (shell-quoted), and a touched step whose placeholders expand
      to nothing is skipped.
    * `pre_push_budget_seconds` — the total time budget across all steps
      (default #{180}). A step gets at most what is left of it.
    * `pre_push_max_attempts` — how many times a red recipe is sent back to the
      worker session before the run escalates (default 2).
    * `prepush_check_on_timeout` — `"proceed"` (default) or `"fail"`: whether a
      step that timed out (or a budget that ran out) blocks the push.

  The older single-command `prepush_check` (+ `_timeout_seconds`) still works
  and is one step named `prepush_check`; `pre_push_checks` wins when both are set.
  """

  alias Arbiter.Worker.SeedPaths

  @default_step_timeout 120
  @default_budget 180
  @default_legacy_timeout 1200

  @type scope :: :all | :touched
  @type step :: %{name: String.t(), cmd: String.t(), timeout_s: pos_integer(), scope: scope()}
  @type spec :: %{
          required(:command) => String.t(),
          required(:timeout_seconds) => pos_integer(),
          required(:on_timeout) => :proceed | :fail,
          required(:steps) => [step()],
          required(:budget_seconds) => pos_integer(),
          required(:max_attempts) => pos_integer() | nil
        }

  @doc "The default `pre_push_budget_seconds`."
  @spec default_budget_seconds() :: pos_integer()
  def default_budget_seconds, do: @default_budget

  @doc "The default legacy `prepush_check_timeout_seconds`."
  @spec default_legacy_timeout_seconds() :: pos_integer()
  def default_legacy_timeout_seconds, do: @default_legacy_timeout

  @doc """
  The recipe configured for `repo` in `workspace` (a `Workspace`, any
  config-bearing map, or `nil`), or `nil` when none is set.
  """
  @spec resolve(term(), String.t() | nil) :: spec() | nil
  def resolve(%{config: %{"worker" => %{} = worker}}, repo) do
    effective = SeedPaths.effective(worker, repo)

    case steps_from(effective) do
      [] -> legacy(effective)
      steps -> build(steps, effective, budget(effective))
    end
  end

  def resolve(_workspace, _repo), do: nil

  defp steps_from(%{"pre_push_checks" => "arbiter"}), do: arbiter_preset()

  defp steps_from(%{"pre_push_checks" => list}) when is_list(list),
    do: Enum.flat_map(list, &step/1)

  defp steps_from(_), do: []

  defp step(%{"cmd" => cmd} = raw) when is_binary(cmd) do
    case String.trim(cmd) do
      "" ->
        []

      cmd ->
        [
          %{
            name: step_name(raw["name"], cmd),
            cmd: cmd,
            timeout_s: positive(raw["timeout_s"], @default_step_timeout),
            scope: scope(raw["scope"])
          }
        ]
    end
  end

  defp step(_), do: []

  defp step_name(name, cmd) do
    case is_binary(name) && String.trim(name) do
      name when is_binary(name) and name != "" -> name
      _ -> cmd |> String.split() |> List.first() |> to_string()
    end
  end

  defp scope("touched"), do: :touched
  defp scope(_), do: :all

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_, default), do: default

  defp budget(effective), do: positive(effective["pre_push_budget_seconds"], @default_budget)

  defp legacy(%{"prepush_check" => command} = effective) when is_binary(command) do
    case String.trim(command) do
      "" ->
        nil

      command ->
        timeout = positive(effective["prepush_check_timeout_seconds"], @default_legacy_timeout)

        build(
          [%{name: "prepush_check", cmd: command, timeout_s: timeout, scope: :all}],
          effective,
          timeout
        )
    end
  end

  defp legacy(_), do: nil

  defp build(steps, effective, budget) do
    %{
      command: Enum.map_join(steps, "\n", & &1.cmd),
      timeout_seconds: budget,
      budget_seconds: budget,
      on_timeout: on_timeout(effective["prepush_check_on_timeout"]),
      max_attempts: max_attempts(effective["pre_push_max_attempts"]),
      steps: steps
    }
  end

  defp on_timeout("fail"), do: :fail
  defp on_timeout(_), do: :proceed

  defp max_attempts(n) when is_integer(n) and n >= 0, do: n
  defp max_attempts(_), do: nil

  @doc """
  The default recipe for this repo (`"pre_push_checks": "arbiter"`): the checks
  behind most of the CI failures workers used to cost a fix pass for — format,
  compile warnings, credo on the touched files, the doc/catalog drift tests, and
  the tests mapped from the changed modules. All run from the repo root, under
  `MIX_ENV=test` so they share the build the tests use.
  """
  @spec arbiter_preset() :: [step()]
  def arbiter_preset do
    [
      %{
        name: "format",
        cmd: "mix format --check-formatted",
        timeout_s: 60,
        scope: :all
      },
      %{
        name: "compile",
        cmd: "MIX_ENV=test mix compile --warnings-as-errors",
        timeout_s: 150,
        scope: :all
      },
      %{
        name: "credo",
        cmd: "MIX_ENV=test mix credo --strict {elixir_files}",
        timeout_s: 90,
        scope: :touched
      },
      %{
        name: "doc_citations",
        cmd:
          "cd apps/arbiter && mix test test/arbiter/review_coverage_design_test.exs " <>
            "test/arbiter/mcp/catalog_doc_drift_test.exs",
        timeout_s: 90,
        scope: :all
      },
      %{
        name: "tests",
        cmd: "scripts/pre-push-tests.sh {test_files}",
        timeout_s: 150,
        scope: :touched
      }
    ]
  end
end
