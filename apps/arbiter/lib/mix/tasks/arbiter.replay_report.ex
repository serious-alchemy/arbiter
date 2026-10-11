defmodule Mix.Tasks.Arbiter.ReplayReport do
  @shortdoc "Offline replays: evidence per competence cell, or the tasks a replay could take"
  @moduledoc """
  Prints the offline replay report (bd-c7lx65, R15 of
  `docs/design/paced-quota-routing-signals.md` §7.2): the replays recorded in a
  window by state, the replay evidence per competence cell (its own source,
  with its own weight, never read into the live competence matrix), and the
  latest replays with their outcome or refusal. With `--candidates`, the
  closed, completed tickets a replay could take instead, and why any cannot.

  **Read-only.** It runs no replay. A replay spends quota, and is admitted only
  into the expiring headroom the live node publishes, so it runs there:

      bin/arbiter rpc 'Arbiter.Release.replay(task_id: "bd-…", account: "claude:default", model: "claude-sonnet-5-5", async: true)'

  ## Usage

      mix arbiter.replay_report                      # last 30 days
      mix arbiter.replay_report --since 7d
      mix arbiter.replay_report --since 2026-10-01 --until 2026-10-08
      mix arbiter.replay_report --candidates --difficulty 2 --type feature --limit 10

  On a release install, which has no Mix toolchain, run
  `bin/arbiter eval 'Arbiter.Release.replay_report()'` (or
  `Arbiter.Release.replay_candidates/1`) instead.
  """

  use Mix.Task

  @switches [
    since: :string,
    until: :string,
    workspace: :string,
    candidates: :boolean,
    repo: :string,
    difficulty: :integer,
    type: :string,
    limit: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    # The database layer only, never the worker fleet or endpoint.
    Mix.Task.run("app.config")
    repo_config = Application.get_env(:arbiter, Arbiter.Repo, [])
    Application.put_env(:arbiter, Arbiter.Repo, Keyword.put(repo_config, :log, false))

    if opts[:candidates] do
      Arbiter.Release.replay_candidates(
        Enum.reject(
          [
            workspace_id: opts[:workspace],
            repo: opts[:repo],
            difficulty: opts[:difficulty],
            issue_type: opts[:type],
            limit: opts[:limit]
          ],
          fn {_key, value} -> is_nil(value) end
        )
      )
    else
      until = parse_dt(opts[:until]) || DateTime.utc_now()

      Arbiter.Release.replay_report(
        since: parse_since(opts[:since], until),
        until: until,
        workspace_id: opts[:workspace]
      )
    end

    :ok
  end

  # `Nd` (days back from `until`) or an ISO date/datetime; default 30 days.
  defp parse_since(nil, until), do: DateTime.add(until, -30 * 86_400, :second)

  defp parse_since(str, until) do
    case Regex.run(~r/^(\d+)d$/, str) do
      [_, n] -> DateTime.add(until, -String.to_integer(n) * 86_400, :second)
      _ -> parse_dt(str) || Mix.raise("bad --since: #{str} (use `Nd` or an ISO date)")
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Date.from_iso8601(str) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end
end
