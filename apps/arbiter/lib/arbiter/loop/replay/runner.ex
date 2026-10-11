defmodule Arbiter.Loop.Replay.Runner do
  @moduledoc """
  Runs one model once for an offline replay (R15, bd-c7lx65): the replayed
  model implementing the ticket (`:implement`), or the scoring reviewer
  reviewing what it did (`:review`), headless, in the replay's sandbox, and
  returns the model's own output lines.

  `Arbiter.Loop.Replay.CliRunner` is the implementation that spawns the agent
  CLIs. `Arbiter.Loop.Replay.run/1` takes `:runner` (a module implementing
  this behaviour, or a two-arity function of the same shape, for tests), else
  `config :arbiter, :loop_replay_runner`. Tests configure `:disabled`, so no
  test spawns a real CLI by accident.

  ## The spec

    * `:replay_id`, `:dir` (the sandbox checkout, the working directory) and
      `:scratch` (the replay's own directory for anything else the spawn needs);
    * `:prompt`;
    * `:provider` (the account's provider atom: `:claude`, `:codex`,
      `:antigravity`, …), `:account_id` and `:model`, which pin the pool the
      run draws on: the one admitted;
    * `:workspace` and `:repo`, whose security policy and guardrail profile
      the run is held to, as a dispatch is;
    * `:timeout_ms`.

  ## The result

  `output` is the model's own text (never a tool's output, so a file that
  happens to contain `VERDICT: APPROVE` cannot score a review), `exit_status`,
  `timed_out` and `duration_ms`. A run that could not be spawned at all is
  `{:error, reason}`.
  """

  alias Arbiter.Tasks.Workspace

  @type role :: :implement | :review

  @type spec :: %{
          replay_id: String.t(),
          dir: Path.t(),
          scratch: Path.t(),
          prompt: String.t(),
          provider: atom(),
          account_id: String.t(),
          model: String.t(),
          workspace: Workspace.t(),
          repo: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @type result :: %{
          output: [String.t()],
          exit_status: integer() | nil,
          timed_out: boolean(),
          duration_ms: non_neg_integer()
        }

  @callback run(role(), spec()) :: {:ok, result()} | {:error, term()}
end
