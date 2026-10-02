defmodule Arbiter.Test.DirectTmuxRunner do
  @moduledoc """
  A `Arbiter.Sessions.Runner` for tests that want a REAL tmux server but no
  systemd (login relay, bd-c99hys).

  `systemd-run --user --scope … tmux -S … new-session …` is reduced to the
  `tmux …` it wraps (with `-f /dev/null`, so the operator's tmux.conf cannot
  interfere), `systemctl` is a no-op success, and everything else runs for
  real. Every call is recorded in a named `Agent` — start it with
  `start_supervised!(DirectTmuxRunner)` — so a test can assert on the argv
  that reached the OS.
  """

  @behaviour Arbiter.Sessions.Runner

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @doc "Every `{command, args}` run so far, oldest first."
  @spec calls() :: [{String.t(), [String.t()]}]
  def calls, do: Enum.reverse(Agent.get(__MODULE__, & &1))

  @impl Arbiter.Sessions.Runner
  def run(command, args, opts) do
    Agent.update(__MODULE__, &[{command, args} | &1])

    case command do
      "systemd-run" ->
        {_wrapper, ["tmux" | tmux_args]} = Enum.split_while(args, &(&1 != "tmux"))
        Arbiter.Sessions.Runner.Host.run("tmux", ["-f", "/dev/null" | tmux_args], opts)

      "systemctl" ->
        {"", 0}

      _ ->
        Arbiter.Sessions.Runner.Host.run(command, args, opts)
    end
  end
end
