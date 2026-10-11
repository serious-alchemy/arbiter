defmodule Arbiter.Loop.Replay.Runner do
  @moduledoc """
  Runs one model once for an offline replay (R15, bd-c7lx65): the replayed
  model implementing the ticket (`:implement`), or the scoring reviewer
  reviewing what it did (`:review`), headless, in the replay's checkout, and
  returns the model's own output lines; and runs the repo's tests on what the
  replayed model left (`:test`), where that model ran.

  `Arbiter.Loop.Replay.CliRunner` is the implementation that spawns the agent
  CLIs. `Arbiter.Loop.Replay.run/1` takes `:runner` (a module implementing
  this behaviour, or a two-arity `run` function of the same shape, for tests,
  which runs on the host), else `config :arbiter, :loop_replay_runner`. Tests
  configure `:disabled`, so no test spawns a real CLI by accident.

  ## Where each side runs (`layout/2`), asked before admission

  Every model a replay runs must be confined: an OS jail on its way out (a
  container, or a provider's own network jail), never only a permission layer.
  `layout/2` says, for `:implement` and for `:review`, the checkout the side
  needs: `{:ok, :sandbox}` for a jailed run on the host
  (`Arbiter.Loop.Replay.Sandbox`), `{:ok, :private_clone}` for one a container
  is handed (it can only mount an `Arbiter.Worker.PrivateClone`), or
  `{:error, reason}` for a side it cannot confine, which refuses the replay
  before admission: no record, no checkout, nothing spent. It is asked before
  there is a replay, so the spec's `:replay_id`, `:dir`, `:scratch` and
  `:prompt` are `nil`.

  ## The spec

    * `:replay_id`, `:dir` (the checkout, the working directory) and
      `:scratch` (the replay's own directory for anything else the spawn needs);
    * `:prompt`;
    * `:provider` (the account's provider atom: `:claude`, `:codex`,
      `:antigravity`, …), `:account_id` and `:model`, which pin the pool the
      run draws on: the one admitted; and `:thinking`, the level to run at
      (`nil`: the adapter's default);
    * `:workspace` and `:repo`, whose security policy and guardrail profile
      the run is held to, as a dispatch is;
    * `:timeout_ms`;
    * for `:test`, the replayed model's side, with `:recipe` (the repo's
      `Arbiter.Worker.PrepushCheck` recipe) and `:base_sha` (what its
      touched-file steps diff against);
    * optionally `:container_opts`, stand-ins for a container spawn's host
      tools (tests).

  ## The result

  For `:implement` and `:review`: `output` is the model's own text (never a
  tool's output, so a file that happens to contain `VERDICT: APPROVE` cannot
  score a review), `exit_status`, `timed_out` and `duration_ms`; optionally
  `usage`, what the run drew as the adapter counts it (tokens, cost), kept on
  the replay's own record. For `:test`: what
  `Arbiter.Worker.PrepushCheck.run_steps/3` returns, run confined as the
  replayed model was, never on the host. A run that could not be started at
  all is `{:error, reason}`.
  """

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.PrepushCheck

  @type role :: :implement | :review | :test

  @type layout :: :sandbox | :private_clone

  @type spec :: %{
          required(:replay_id) => String.t() | nil,
          required(:dir) => Path.t() | nil,
          required(:scratch) => Path.t() | nil,
          required(:prompt) => String.t() | nil,
          required(:provider) => atom(),
          required(:account_id) => String.t(),
          required(:model) => String.t(),
          required(:thinking) => String.t() | nil,
          required(:workspace) => Workspace.t(),
          required(:repo) => String.t() | nil,
          required(:timeout_ms) => pos_integer(),
          optional(:recipe) => PrepushCheck.spec(),
          optional(:base_sha) => String.t(),
          optional(:container_opts) => keyword()
        }

  @type result :: %{
          required(:output) => [String.t()],
          required(:exit_status) => integer() | nil,
          required(:timed_out) => boolean(),
          required(:duration_ms) => non_neg_integer(),
          optional(:usage) => map()
        }

  @callback run(role(), spec()) ::
              {:ok, result()}
              | {:ok, %{result: PrepushCheck.result(), steps: [PrepushCheck.step_result()]}}
              | {:error, term()}

  @callback layout(:implement | :review, spec()) :: {:ok, layout()} | {:error, term()}
end
