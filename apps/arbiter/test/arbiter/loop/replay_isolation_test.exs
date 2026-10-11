defmodule Arbiter.Loop.ReplayIsolationTest do
  @moduledoc """
  bd-c7lx65 (R15): the no-regression invariant
  (`docs/design/paced-quota-routing-signals.md` §9) for the offline replay
  harness, and its promise never to merge or touch production.

    * **Off means identical (I1).** The harness is a layer only an operator
      invokes (`Arbiter.Release.replay/1`). No supervisor, scheduler, dispatch,
      routing, gate, budget, seat, board or competence path names it, so with
      it off, the default, every decision surface is the code it was.
    * **One eligible account means identical (I2).** A replay is recorded, and
      while it runs holds its seats, only in its own table. With one eligible
      account and every router layer on, routing and the gate decide exactly
      as with no replay at all, and the live seat count does not move.
    * **It never merges and never touches production.** The harness names no
      merge, forge, tracker, dispatch, ticket-transition, competence-matrix or
      live-record path, and runs no `git push`. `Arbiter.Loop.ReplayTest`
      shows it at run time: the checkout, its remote, the ticket and every
      live table are as they were after a replay.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Loop.ReplayRun
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Throttle
  alias Arbiter.Quota.Seats
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @apps Path.expand("../../../..", __DIR__)

  # The layer, by name: its modules (or an alias of them) and its table.
  @names ~r/Loop\.Replay\b|Loop\.ReplayRun\b|\breplay_runs\b/

  # Who may name it: the harness, its domain's resource list, and the
  # operator's entry points.
  @named_by ~w(
    arbiter/lib/arbiter/loop/replay.ex
    arbiter/lib/arbiter/loop/replay_run.ex
    arbiter/lib/arbiter/loop.ex
    arbiter/lib/arbiter/release.ex
    arbiter/lib/mix/tasks/arbiter.replay_report.ex
  )

  defp lib_files do
    @apps
    |> Path.join("*/lib/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @apps))
  end

  defp harness_files do
    Enum.filter(lib_files(), fn path ->
      path in ~w(arbiter/lib/arbiter/loop/replay.ex arbiter/lib/arbiter/loop/replay_run.ex) or
        String.starts_with?(path, "arbiter/lib/arbiter/loop/replay/")
    end)
  end

  describe "off means identical (I1)" do
    test "nothing outside the harness and its operator entry points names it" do
      offenders =
        lib_files()
        |> Enum.reject(
          &(&1 in @named_by or String.starts_with?(&1, "arbiter/lib/arbiter/loop/replay/"))
        )
        |> Enum.filter(&(@apps |> Path.join(&1) |> File.read!() =~ @names))

      assert offenders == []
    end

    test "nothing starts it: it is not in any supervision tree, and runs only when invoked" do
      for path <- lib_files(), String.ends_with?(path, "application.ex") do
        refute @apps |> Path.join(path) |> File.read!() =~ ~r/Replay/, path
      end
    end
  end

  describe "it never merges and never touches production" do
    # Modules (and their submodules) the harness must never call.
    @forbidden_modules ~w(
      Arbiter.Workflows.MergeQueue Arbiter.Mergers Arbiter.GitHub Arbiter.Trackers
      Arbiter.Worker.Dispatch Arbiter.Workflows.DispatchQueue Arbiter.Tasks.PullRequest
      Arbiter.Tasks.Lifecycle Arbiter.Loop.Apply Arbiter.Loop.Canary Arbiter.Settings
      Arbiter.ReviewGate Arbiter.Usage Arbiter.Messages
    )

    # Functions of allowed modules that publish or sync a branch.
    @forbidden_calls [
      {"Arbiter.Worker.Worktree", :push},
      {"Arbiter.Worker.Worktree", :create},
      {"Arbiter.Worker.PrivateClone", :sync_back},
      {"Arbiter.Worker.PrivateClone", :create}
    ]

    # Reads that live under a forbidden namespace: the workspace's `repo_paths`
    # lookup, in the order `Arbiter.Worker.Dispatch` provisions worktrees from.
    @read_only_calls [{"Arbiter.Mergers.LocalCompare", :repo_path}]

    defp forbidden?(module),
      do: Enum.any?(@forbidden_modules, &(module == &1 or String.starts_with?(module, &1 <> ".")))

    test "the harness calls no merge, forge, tracker, dispatch, transition or live-record path" do
      read_only_modules = Enum.map(@read_only_calls, &elem(&1, 0))

      for path <- harness_files() do
        refs = path |> then(&Path.join(@apps, &1)) |> references()

        for {module, fun} = call <- refs.calls,
            forbidden?(module) and call not in @read_only_calls do
          flunk("#{path} calls #{module}.#{fun}")
        end

        for module <- refs.aliases, forbidden?(module), module not in read_only_modules do
          flunk("#{path} names #{module}")
        end

        for {module, fun} = call <- refs.calls, call in @forbidden_calls do
          flunk("#{path} calls #{module}.#{fun}")
        end
      end
    end

    test "the harness runs no `git push` and opens no PR" do
      for path <- harness_files() do
        refs = path |> then(&Path.join(@apps, &1)) |> references()
        refute "push" in refs.strings, "#{path} has a git push"
        refute Enum.any?(refs.strings, &(&1 in ["pr", "create"])), "#{path} has a gh pr call"
      end
    end
  end

  describe "one eligible account means identical (I2)" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "replay-iso-#{System.unique_integer([:positive])}",
          config: %{
            "routing" => %{
              "provider_selection" => "scored",
              "scoring" => %{"mode" => "enforce", "competence" => true}
            }
          }
        })

      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "claude-#{System.unique_integer([:positive])}",
          quota_config: %{"threshold_mode" => "paced"}
        })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id,
        implementer_position: 0
      })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      quota = %AnthropicQuota{
        provider: "claude",
        utilization_5h: 0.30,
        reset_5h_at: DateTime.add(now, 9_000),
        status_5h: "allowed",
        utilization_7d: 0.40,
        reset_7d_at: DateTime.add(now, 302_400),
        status_7d: "allowed",
        captured_at: now
      }

      task = Ash.create!(Issue, %{title: "route me", difficulty: 2, workspace_id: ws.id})

      %{ws: ws, account: account, quota: quota, task: task, now: now}
    end

    defp decisions(ctx) do
      routing =
        ProviderRouting.evaluate(ctx.ws, ctx.task,
          quota_fun: fn _account -> ctx.quota end,
          gemini_code: "antigravity",
          now: ctx.now
        )

      gate = Throttle.check(ctx.task, ctx.quota, ctx.ws, account: ctx.account, now: ctx.now)

      %{routing: routing, gate: gate, seats: Seats.counts()}
    end

    test "routing, the gate and the seats decide as before while replays are recorded and running",
         ctx do
      before = decisions(ctx)
      assert [_one] = before.routing["candidates"]

      for state <- [:running, :scored] do
        Ash.create!(ReplayRun, %{
          task_id: ctx.task.id,
          workspace_id: ctx.ws.id,
          provider: "claude",
          account_id: ctx.account.id,
          model: "claude-sonnet-5-5",
          pool: "claude",
          reviewer_provider: "claude",
          reviewer_account_id: ctx.account.id,
          reviewer_model: "claude-opus-5-5",
          reviewer_pool: "claude",
          state: state,
          started_at: ctx.now
        })
      end

      assert decisions(ctx) == before
    end
  end

  # ---- source references, by AST (docs and prompt text are not code) ------------

  defp references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
    aliases = alias_table(ast)

    {_, acc} =
      Macro.prewalk(ast, %{aliases: [], calls: [], strings: []}, fn
        {:@, _, [{doc, _, _}]}, acc when doc in [:moduledoc, :doc, :typedoc] ->
          {nil, acc}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, _} = node, acc when is_atom(fun) ->
          {node, %{acc | calls: [{expand(parts, aliases), fun} | acc.calls]}}

        {:__aliases__, _, parts} = node, acc ->
          {node, %{acc | aliases: [expand(parts, aliases) | acc.aliases]}}

        string, acc when is_binary(string) ->
          {string, %{acc | strings: [string | acc.strings]}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp alias_table(ast) do
    {_, table} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts} | rest]} = node, table ->
          as =
            case rest do
              [[as: {:__aliases__, _, [short]}]] -> short
              _ -> List.last(parts)
            end

          {node, Map.put(table, as, Enum.join(parts, "."))}

        node, table ->
          {node, table}
      end)

    table
  end

  defp expand([head | tail], aliases) do
    case Map.fetch(aliases, head) do
      {:ok, full} -> Enum.join([full | Enum.map(tail, &Atom.to_string/1)], ".")
      :error -> Enum.map_join([head | tail], ".", &Atom.to_string/1)
    end
  end
end
