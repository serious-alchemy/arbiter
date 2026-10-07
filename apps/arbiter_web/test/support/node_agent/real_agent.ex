defmodule ArbiterWeb.RealAgent do
  @moduledoc """
  A real node agent as its own OS process, for the `:node_agent` end-to-end suite
  (`docs/design/remote-workers.md` §18 row 13, `docs/remote-workers-runbook.md`).

  Every other node test in this repo runs the agent inside the test VM against a
  stand-in `podman`. This one boots a **second BEAM** in the agent role,
  `ARB_ROLE=agent mix run --no-halt`, the way the join script's systemd unit boots
  the release: `config/runtime.exs` turns the role into application config,
  `Arbiter.Application` starts only `Arbiter.NodeAgent.Supervisor`, and the agent
  reads its URL, home and credential file from the environment the unit's
  `agent.env` would carry. It reaches the test VM over a real WebSocket and real
  HTTP (`ArbiterWeb.NodeTestEndpoint`) and drives the host's real rootless
  `podman`.

  The child's output goes to `<dir>/agent.log`. It is stopped by its exact OS pid
  (`Arbiter.Worker.OsProcess.kill_tree/1`), never by name: this repo's dogfooded
  coordinator is a `mix`/BEAM process on the same host.
  """

  alias Arbiter.Worker.OsProcess

  @app_dir Path.expand("../../..", __DIR__)

  defstruct [:port, :os_pid, :dir, :node_home, :log, :env]

  @type t :: %__MODULE__{}

  @doc """
  Boot an agent. `env` is the agent's configuration as `agent.env` carries it
  (`ARB_NODE_URL`, `ARB_NODE_HOME`, `ARB_NODE_CREDENTIAL_FILE`, ...); everything
  else of the caller's `ARB_*` environment is cleared so a worker's own task
  variables never reach the child.
  """
  @spec start(Path.t(), %{String.t() => String.t()}) :: t()
  def start(dir, %{} = env) do
    File.mkdir_p!(dir)
    log = Path.join(dir, "agent.log")
    mix = System.find_executable("mix") || raise "mix is not on PATH"

    inherited_arb =
      for {name, _} <- System.get_env(), String.starts_with?(name, "ARB"), do: {name, false}

    child_env =
      Map.new(inherited_arb)
      |> Map.merge(%{
        "MIX_ENV" => "test",
        "ARB_ROLE" => "agent",
        "ROOTDIR" => false,
        "BINDIR" => false
      })
      |> Map.merge(session_env())
      |> Map.merge(env)
      |> Enum.map(fn
        {k, false} -> {String.to_charlist(k), false}
        {k, v} -> {String.to_charlist(k), String.to_charlist(v)}
      end)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :exit_status,
        :binary,
        cd: @app_dir,
        env: child_env,
        args: [
          "-c",
          ~S(exec "$@" >>"$0" 2>&1),
          log,
          mix,
          "run",
          "--no-compile",
          "--no-deps-check",
          "--no-halt"
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    %__MODULE__{
      port: port,
      os_pid: os_pid,
      dir: dir,
      node_home: env["ARB_NODE_HOME"],
      log: log,
      env: env
    }
  end

  # What a systemd user unit has and a bare worker shell may not: the user runtime
  # directory (the agent's secrets tmpfs, podman's run root) and the user bus.
  defp session_env do
    {uid, _} = System.cmd("id", ["-u"])
    dir = "/run/user/" <> String.trim(uid)

    for {name, value} <- [
          {"XDG_RUNTIME_DIR", dir},
          {"DBUS_SESSION_BUS_ADDRESS", "unix:path=" <> dir <> "/bus"}
        ],
        File.exists?(dir),
        System.get_env(name) in [nil, ""],
        into: %{},
        do: {name, value}
  end

  @doc "Stop the agent (SIGKILL of its process tree, by pid); idempotent."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{os_pid: os_pid, port: port}) do
    _ = OsProcess.kill_tree(os_pid)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 -> :ok
    end
  end

  @doc "True while the agent's OS process runs."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{os_pid: os_pid}), do: File.exists?("/proc/#{os_pid}")

  @doc "The last `lines` lines of the agent's log (for a failure message)."
  @spec log_tail(t(), pos_integer()) :: String.t()
  def log_tail(%__MODULE__{log: log}, lines \\ 40) do
    case File.read(log) do
      {:ok, body} -> body |> String.split("\n") |> Enum.take(-lines) |> Enum.join("\n")
      {:error, _} -> "(no agent log)"
    end
  end

  @doc "The agent's own status file (`arbiter-node status`), decoded, or `nil`."
  @spec status(t()) :: map() | nil
  def status(%__MODULE__{node_home: home}) do
    with {:ok, body} <- File.read(Path.join(home, "status.json")),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _ -> nil
    end
  end
end
