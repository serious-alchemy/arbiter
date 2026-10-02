defmodule Arbiter.Accounts.LoginRunner.Sweep do
  @moduledoc """
  Boot-time cleanup of stale login sessions (bd-c99hys).

  A `LoginRunner` dies with the node, but the tmux server holding its CLI
  (inside its own systemd scope) does not, and it may be parked on a prompt that
  a one-time code was already minted for. Nothing can reconnect a restarted node
  to that login — the requester's LiveView and private topic are gone — so every
  `arb-login-*` session found at boot is killed:

    * every non-ended `:login` Session row, through `Arbiter.Sessions.kill/2`
      (tmux session, scope, row);
    * every `arb-login-*` tmux session still answering on an `arb-login-*.sock`
      with no row behind it (an exact-name `kill-session`, never a pattern kill
      of processes), and the dead socket file.

  Primary-gated like the other boot sweeps: a transient duplicate boot must not
  kill the live instance's in-flight logins.
  """

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session

  require Ash.Query
  require Logger

  @prefix "arb-login-"

  @spec sweep_on_boot(keyword()) :: %{killed: non_neg_integer()}
  def sweep_on_boot(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      result = sweep(opts)

      if result.killed > 0,
        do: Logger.info("login relay boot sweep: killed #{result.killed} stale login session(s)")

      result
    else
      %{killed: 0}
    end
  rescue
    e ->
      Logger.error("login relay boot sweep crashed: #{Exception.message(e)}")
      %{killed: 0}
  end

  @spec sweep(keyword()) :: %{killed: non_neg_integer()}
  def sweep(opts \\ []) do
    runner = Sessions.runner(opts)
    %{killed: kill_rows(runner) + kill_stray_sockets(runner)}
  end

  defp kill_rows(runner) do
    Session
    |> Ash.Query.filter(kind == :login and status != :ended)
    |> Ash.read!()
    |> Enum.count(fn session ->
      match?(
        {:ok, _},
        Sessions.kill(session.id,
          runner: runner,
          reason: "login relay boot sweep: stale login session"
        )
      )
    end)
  end

  defp kill_stray_sockets(runner) do
    case Naming.socket_dir() do
      {:ok, dir} ->
        dir
        |> Path.join(@prefix <> "*.sock")
        |> Path.wildcard()
        |> Enum.map(&sweep_socket(runner, &1))
        |> Enum.sum()

      {:error, :no_runtime_dir} ->
        0
    end
  end

  defp sweep_socket(runner, socket) do
    names =
      case runner.run("tmux", ["-S", socket, "list-sessions", "-F", "\#{session_name}"],
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          out |> String.split("\n", trim: true) |> Enum.filter(&String.starts_with?(&1, @prefix))

        _ ->
          []
      end

    killed =
      Enum.count(names, fn name ->
        match?(
          {_, 0},
          runner.run("tmux", ["-S", socket, "kill-session", "-t", name], stderr_to_stdout: true)
        )
      end)

    # A socket nobody answers on is a leftover file.
    if match?({_, 0}, runner.run("tmux", ["-S", socket, "has-session"], stderr_to_stdout: true)) do
      :ok
    else
      File.rm(socket)
    end

    killed
  end
end
