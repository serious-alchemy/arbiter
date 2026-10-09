defmodule Arbiter.Worker.SshAgent do
  @moduledoc """
  A per-worker `ssh-agent` holding exactly the key a declared `prod_ssh`
  permission grants (`docs/design/guardrail-profiles.md` §5.1, §5.5, G14).

  The key reaches the worker as a **socket, never a file or an env var**: the
  jail binds this agent's socket (`Arbiter.Worker.Jail`'s `:ssh_agent` option)
  and points `SSH_AUTH_SOCK` at it, `~/.ssh` stays hidden, and the worker can
  use the key to authenticate but cannot read it. The operator's own agent
  (which holds every key they own) is never what a `prod_ssh` worker sees.

    * One agent per owner (the worker): the socket name is derived from the
      owner pid, so a resume or nudge of the same worker finds the live agent
      and reuses it, and a socket named in an earlier argv stays valid.
    * It dies with the owner. The agent runs under a tiny `sh` wrapper that
      kills it and removes the socket when its stdin closes, which happens on
      `stop/1`, on owner exit, and on BEAM death (so a crashed server leaves no
      agent holding a prod key).
    * The private key is written to a `0600` file in the `0700` agent dir only
      for the `ssh-add`, and deleted at once.

  Every failure is returned. The caller must refuse the spawn on `{:error, _}`:
  a `prod_ssh` worker without its agent must not fall back to the operator's.
  """

  use GenServer

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.ReleaseEnv

  # sockaddr_un.sun_path is 108 bytes including the NUL.
  @max_socket_bytes 107
  @ready_attempts 50

  @type handle :: %{socket: Path.t(), pid: pid()}

  @wrapper ~S"""
  ssh-agent -D -a "$1" >/dev/null 2>&1 &
  p=$!
  while read -r _; do :; done
  kill "$p" 2>/dev/null
  rm -f "$1"
  """

  @doc "The default directory agent sockets live in."
  @spec default_dir() :: Path.t()
  def default_dir, do: Path.join(Paths.scratch_root(), "ssh-agent")

  @doc """
  Creates (`0700`) and returns the default agent dir. The jail masks this dir
  for every worker (`Arbiter.Worker.Jail.mask_paths/0`); it has to exist by
  then, because a read-only bind of `/` shows a directory created after the
  jail started.
  """
  @spec ensure_default_dir() :: Path.t()
  def ensure_default_dir do
    dir = default_dir()
    _ = ensure_dir(dir)
    dir
  end

  @doc """
  Starts (or finds) the agent for `:owner` holding `:key` (the private key text).
  Options: `:owner` (required pid), `:key` (required), `:dir`.
  Returns `{:ok, %{socket:, pid:}}`.
  """
  @spec start(keyword()) :: {:ok, handle()} | {:error, term()}
  def start(opts) do
    with owner when is_pid(owner) <- Keyword.get(opts, :owner),
         key when is_binary(key) and key != "" <- Keyword.get(opts, :key) do
      dir = Keyword.get(opts, :dir) || default_dir()
      socket = socket_path(owner, dir)

      with :ok <- check_length(socket),
           :ok <- ensure_dir(dir) do
        start_or_reuse(owner, key, dir, socket)
      end
    else
      _ -> {:error, :bad_options}
    end
  end

  @doc "Stops the agent and removes its socket. Idempotent."
  @spec stop(handle() | pid()) :: :ok
  def stop(%{pid: pid}), do: stop(pid)

  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The socket path for `owner` under `dir`."
  @spec socket_path(pid(), Path.t()) :: Path.t()
  def socket_path(owner, dir) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(owner))

    Path.join(
      dir,
      "a" <> Base.encode32(binary_part(hash, 0, 8), case: :lower, padding: false) <> ".sock"
    )
  end

  defp check_length(socket) do
    if byte_size(socket) <= @max_socket_bytes,
      do: :ok,
      else: {:error, {:socket_path_too_long, socket}}
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp start_or_reuse(owner, key, dir, socket) do
    case live_agent(socket) do
      {:ok, pid} ->
        # Same owner, possibly a different key (a revise round after the
        # binding's `ssh_key_secret` changed): never hand back the old key.
        case ensure_key(pid, key) do
          :ok -> {:ok, %{socket: socket, pid: pid}}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        case GenServer.start(__MODULE__, {owner, key, dir, socket}, name: name(socket)) do
          {:ok, pid} -> {:ok, %{socket: socket, pid: pid}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_key(pid, key) do
    GenServer.call(pid, {:ensure_key, key}, 15_000)
  catch
    :exit, reason -> {:error, {:ssh_agent_unavailable, reason}}
  end

  defp fingerprint(key), do: :crypto.hash(:sha256, key)

  # The owner's agent process, when it is still serving. The owner-derived
  # socket name is the whole identity, so look for the GenServer by name.
  defp live_agent(socket) do
    case :global.whereis_name({__MODULE__, socket}) do
      pid when is_pid(pid) -> {:ok, pid}
      :undefined -> :none
    end
  end

  # `:global`, not a registered atom: a name per worker run would leak atoms.
  defp name(socket), do: {:global, {__MODULE__, socket}}

  # ---- server ------------------------------------------------------------------

  @impl true
  def init({owner, key, dir, socket}) do
    Process.flag(:trap_exit, true)
    # A stale socket from a crashed run would make `ssh-agent -a` fail.
    _ = File.rm(socket)

    with sh when is_binary(sh) <- System.find_executable("sh"),
         %{} <- agent_binary(),
         add when is_binary(add) <- System.find_executable("ssh-add") do
      port =
        Port.open({:spawn_executable, sh}, [
          :binary,
          :use_stdio,
          :exit_status,
          args: ["-c", @wrapper, "sh", socket],
          # Release-env scrub (bd-4hkzn3): the agent must not inherit ROOTDIR & co.
          env: port_env()
        ])

      case ready(socket, port) |> add_key(add, key, dir, socket) do
        :ok ->
          ref = Process.monitor(owner)

          {:ok,
           %{
             owner_ref: ref,
             port: port,
             socket: socket,
             dir: dir,
             add: add,
             fingerprint: fingerprint(key)
           }}

        {:error, reason} ->
          close(port, socket)
          {:stop, reason}
      end
    else
      _ -> {:stop, :ssh_agent_not_found}
    end
  end

  defp port_env do
    Enum.map(ReleaseEnv.port_env([]), fn {name, value} ->
      {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
    end)
  end

  defp ready(socket, port, attempt \\ 0) do
    cond do
      match?({:ok, %File.Stat{type: :other}}, File.stat(socket)) ->
        :ok

      attempt >= @ready_attempts ->
        {:error, {:ssh_agent_not_ready, socket}}

      true ->
        receive do
          {^port, {:exit_status, status}} -> {:error, {:ssh_agent_exited, status}}
        after
          100 -> ready(socket, port, attempt + 1)
        end
    end
  end

  defp add_key(:ok, add, key, dir, socket) do
    file = Path.join(dir, Path.basename(socket, ".sock") <> ".key")

    try do
      with :ok <- File.write(file, ensure_newline(key), [:binary]),
           :ok <- File.chmod(file, 0o600) do
        case ReleaseEnv.cmd(add, [file], env: [{"SSH_AUTH_SOCK", socket}], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> {:error, {:ssh_add_failed, String.trim(out)}}
        end
      end
    after
      File.rm(file)
    end
  end

  defp add_key(error, _add, _key, _dir, _socket), do: error

  defp agent_binary do
    if System.find_executable("ssh-agent"), do: %{}, else: nil
  end

  defp ensure_newline(key), do: if(String.ends_with?(key, "\n"), do: key, else: key <> "\n")

  @impl true
  def handle_call({:ensure_key, key}, _from, %{fingerprint: fp} = state) do
    case fingerprint(key) do
      ^fp ->
        {:reply, :ok, state}

      new_fp ->
        %{add: add, dir: dir, socket: socket} = state

        with {_, 0} <-
               ReleaseEnv.cmd(add, ["-D"],
                 env: [{"SSH_AUTH_SOCK", socket}],
                 stderr_to_stdout: true
               ),
             :ok <- add_key(:ok, add, key, dir, socket) do
          {:reply, :ok, %{state | fingerprint: new_fp}}
        else
          {out, _} when is_binary(out) ->
            {:reply, {:error, {:ssh_add_failed, String.trim(out)}}, state}

          {:error, _} = error ->
            # The agent may now hold no key or a half-replaced set: stop it
            # rather than serve something other than what was asked for.
            {:stop, :normal, error, state}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port, socket: socket}), do: close(port, socket)
  def terminate(_reason, _state), do: :ok

  # Closing the port closes the wrapper's stdin: it kills the agent and removes
  # the socket. Removing it here too covers a wrapper that was already gone.
  defp close(port, socket) do
    Port.close(port)
    _ = File.rm(socket)
    :ok
  catch
    _, _ ->
      _ = File.rm(socket)
      :ok
  end
end
