defmodule ArbiterCli.Cmd.Dispatch do
  @moduledoc """
  `arb dispatch <task-id> [<repo>] [--provider claude|gemini|codex|grok | --no-agent] [--model <name>] [--force] [--over-cap] [--force-quota [--force-quota-reason <why>]]`
  — spawn a worker to work on a task.

  POSTs to `/api/workers/dispatch`. The server transitions the task to
  `:active`, starts a worker GenServer under
  `Arbiter.Worker.Supervisor`, attaches `Arbiter.Workflows.Work` via
  the WorkflowMachine, and spawns an agent subprocess in the worktree.

  By default (no worker flag) the server reads the workspace's `agent.type`
  config and spawns that agent. Use `--provider` to force a specific provider,
  or `--no-agent` to park the task for a manual attach instead. The flags are
  sent to the server as given and judged there (`Arbiter.Worker.Dispatch.Params`,
  the same rules as the MCP `worker_dispatch` tool): `--no-agent` together with a
  provider flag is refused, nothing is spawned or parked; an unknown provider is
  refused with the list of valid ones.

  Flags:
    --provider <p>   force the worker provider regardless of the workspace's
                     `agent.type`. One of `claude` | `gemini` | `codex` | `grok`.
                     `claude` requires the `claude` CLI on PATH (consumes
                     Anthropic credits); `gemini` requires the `agy`/`gemini`
                     CLI on PATH (consumes Google credits); `codex` requires the
                     `codex` CLI on PATH (consumes OpenAI credits); `grok` requires
                     the `grok` CLI on PATH and a grok login.
    --with-claude    DEPRECATED alias for `--provider claude`.
    --with-gemini    DEPRECATED alias for `--provider gemini`.
    --no-agent       dry dispatch — move the task to `:active` for a hand
                     to attach, with no agent spawned. Preserves the old
                     manual-attach path. Cannot be combined with `--provider`,
                     `--with-claude` or `--with-gemini`.
    --model <name>   one-shot override of the model the worker session runs
                     on (`haiku|sonnet|opus`). Takes precedence over the
                     workspace's `agent.config.model` and any routing rule
                     for the task.
    --force          dispatch a ticket that is not Ready — in Backlog, or
                     blocked by open dependencies. Without it the server
                     refuses such a dispatch and says why. The bypass is
                     recorded as a `dispatch_forced` event.
    --over-cap       dispatch even though the provider account the run would
                     use has no free slot (its `max_concurrent`, or this
                     workspace's share, is reached). Without it the server
                     refuses with the account, its cap and the runs holding
                     it. The override is recorded as an `account_cap_override`
                     event. Independent of `--force`.
    --force-quota    ADVANCED: bypass the quota gate for this dispatch. Use only
                     when the gate holds despite judged-important work. Requires
                     explicit authorization; the quota gate protects against
                     spend overage. The bypass is recorded with who ran it.
    --force-quota-reason <why>
                     the rationale recorded with the `--force-quota` bypass.
                     Requires `--force-quota`.
    --json           emit JSON instead of human-readable text
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [
    json: :boolean,
    provider: :string,
    with_claude: :boolean,
    with_gemini: :boolean,
    no_agent: :boolean,
    model: :string,
    force: :boolean,
    over_cap: :boolean,
    force_quota: :boolean,
    force_quota_reason: :string
  ]

  @doc "Every switch `arb dispatch` takes (read by the field-exposure guard test)."
  @spec switches() :: keyword()
  def switches, do: @switches

  # Pre-existing complexity 15 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket dispatch", switches: @switches)

      mode = if opts[:json], do: :json, else: :text
      model = opts[:model]

      {task_id, repo} =
        case rest do
          [id] -> {id, nil}
          [id, repo] -> {id, repo}
          [] -> Output.die("dispatch requires a ticket id (e.g. `arb dispatch bd-abc123`)")
          _ -> Output.die("dispatch takes at most two positional arguments: <task-id> [<repo>]")
        end

      body =
        %{"task_id" => task_id}
        # Every selector is sent as typed — the server rejects a combination it
        # won't honour (`--no-agent` + `--provider`) instead of this client
        # silently dropping one of them (D-W-5), and owns the provider list
        # (D-W-10), so there is no client-side copy to drift.
        |> maybe_put("provider", opts[:provider])
        |> maybe_put("with_claude", if(opts[:with_claude], do: true))
        |> maybe_put("with_gemini", if(opts[:with_gemini], do: true))
        |> maybe_put("no_agent", if(opts[:no_agent], do: true))
        |> maybe_put("repo", repo)
        |> maybe_put("model", model)
        |> maybe_put("force", if(opts[:force], do: true))
        |> maybe_put("over_cap", if(opts[:over_cap], do: true))
        |> maybe_put("force_quota", if(opts[:force_quota], do: true))
        |> maybe_put("force_quota_reason", opts[:force_quota_reason])

      case Client.post("/api/workers/dispatch", body) do
        {:ok, payload} -> emit(payload, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Dispatch:")
    IO.puts("  Ticket:    #{task["id"]} — #{task["title"]}")
    IO.puts("  State:    #{task["state"]}")
    IO.puts("  Worker:  #{worker["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["worktree_path"] do
      nil -> :ok
      path -> IO.puts("  Worktree: #{path}")
    end

    case payload["claude_started"] do
      true -> IO.puts("  Worker: started")
      _ -> :ok
    end
  end
end
