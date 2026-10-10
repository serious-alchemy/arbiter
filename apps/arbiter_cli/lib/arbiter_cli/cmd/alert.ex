defmodule ArbiterCli.Cmd.Alert do
  @moduledoc """
  System alerts (bd-7gt8rm):

      arb alert list [--kind K] [-w WORKSPACE]
                                        — the active alerts, oldest first

  A system alert is a problem with the installation rather than a ticket: an
  expired credential, the quota poll failing, overage spend or a task's worker
  spend past its threshold. It clears by itself when its condition does, so the
  list is exactly what is still wrong. Omitting `-w` lists every workspace.

  `--kind` is one of `credential_expired`, `quota_poll_failing`,
  `quota_snapshot_stale`, `overage_alert`, `budget_exceeded`, `spend_cap`. Coordinator only.
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv,
          command: "arb alert",
          switches: [workspace: :string, kind: :string]
        )

      case rest do
        ["list" | _] -> list(opts, mode)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "arb: unknown alert subcommand")
    IO.puts(:stderr, "Run `arb alert --help` for usage.")
    Output.halt(2)
  end

  defp list(opts, mode) do
    params =
      []
      |> put_workspace(opts)
      |> put_flag(opts, :kind)

    case Client.get("/api/alerts", params) do
      {:ok, body} ->
        if mode == :json, do: IO.puts(Jason.encode!(body)), else: print_list(body)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp print_list(body) do
    case body["alerts"] || [] do
      [] ->
        IO.puts("No active system alerts.")

      alerts ->
        IO.puts("ALERTS (#{length(alerts)} active)")
        Enum.each(alerts, &print_alert/1)
    end
  end

  defp print_alert(a) do
    IO.puts("  [#{a["kind"]}] #{a["subject"]}")
    IO.puts("      #{a["detail"]}")

    IO.puts(
      "      raised #{a["raised_at"]}, last #{a["last_raised_at"]}, x#{a["raise_count"]}" <>
        workspace_suffix(a["workspace_id"])
    )
  end

  defp workspace_suffix(nil), do: ""
  defp workspace_suffix(id), do: " (workspace #{id})"

  defp put_flag(params, opts, key) do
    case opts[key] do
      nil -> params
      value -> [{key, value} | params]
    end
  end

  # `--workspace` / `-w` / ARB_WORKSPACE, resolved to the workspace id.
  defp put_workspace(params, opts) do
    case Workspace.selected_id(opts[:workspace]) do
      nil -> params
      id -> [{:workspace, id} | params]
    end
  end
end
