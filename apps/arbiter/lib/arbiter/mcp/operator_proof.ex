defmodule Arbiter.MCP.OperatorProof do
  @moduledoc """
  Who may mint a coordinator token without already holding one (bd-8381tk).

  Workers, reviewers and sessions run on the same host **and as the same Unix
  user** as the operator, so neither "the request came from loopback" nor
  "the file is mode 0600" tells the operator apart from a worker. What does
  differ is *where the process came from*: everything Arbiter runs is started
  by the server's own BEAM, while the operator's shell is not.

  `Arbiter.MCP.OperatorSocket` accepts connections on a Unix domain socket,
  reads the kernel-attested peer credentials (`SO_PEERCRED`: pid, uid, gid,
  recorded at `connect()` time and not forgeable by the client), and asks
  `authorize/2` whether that peer is the operator:

    1. **Same Unix user as the server.** Any other uid is refused. (The socket
       file is also mode 0600 in a 0700 directory, so another user can't
       connect in the first place.)
    2. **Not descended from the server.** The peer's parent chain is walked
       through `/proc/<pid>/stat`. If it reaches the server's own OS pid, the
       peer is a worker, reviewer or session, or something one of them
       started, and is refused. The server itself is refused too.
    3. **Not inside the server's service cgroup.** When the server runs as a
       systemd unit (its cgroup ends in `.service`, like the release's
       `arbiter.service`), every process it spawns inherits that cgroup. That
       includes a double-forked orphan that has been reparented to
       `systemd --user` and so escaped check 2. A peer in that cgroup, or
       below it, is refused. A dev server run from a terminal shares the
       terminal's scope with the operator's shell, so this check is skipped
       there and only check 2 applies.

  Anything unreadable fails closed: a peer whose `/proc` entry disappears
  mid-walk, a pid of 0, a host without `/proc`.

  ## What this does and does not stop

  A jailed worker (agy under `Arbiter.Worker.Jail`) cannot reach the socket
  at all: its directory sits under `/run/user/<uid>`, which the jail blanks,
  and the jail masks the fallback directory too. It also can't escape
  `arbiter.service` through `systemd-run --user`, because the session bus is
  masked. An **unjailed** worker (Claude today) is refused on the paths it
  would actually take: `arb mcp token mint`, `curl` to the HTTP route, a
  script that connects to the socket. But it runs as the operator with full
  host access, so it could still escape deliberately with
  `systemd-run --user --scope` or by moving itself to another cgroup. For
  such a worker this is a guardrail, not a hard boundary. See
  docs/worker-security.md, "Operator proof for token minting".
  """

  @type peer :: %{pid: integer(), uid: integer(), gid: integer()}
  @type reason ::
          :foreign_uid
          | :unknown_peer
          | :peer_unreadable
          | :spawned_by_arbiter
          | :in_arbiter_cgroup

  # Deeper than any real process tree; bounds the walk against a /proc loop.
  @max_depth 256

  @doc """
  `:ok` if `peer` is the operator, `{:error, reason}` otherwise.

  Options (all default to the running VM's own values; overridden by tests):

    * `:server_pid`: the server's OS pid (`System.pid/0`)
    * `:server_uid`: the server's uid
    * `:server_cgroup`: the server's dedicated service cgroup, or `nil` to skip
      check 3 (`dedicated_cgroup/1` of `/proc/self/cgroup`)
    * `:proc_root`: `"/proc"`
  """
  @spec authorize(peer(), keyword()) :: :ok | {:error, reason()}
  def authorize(%{pid: pid, uid: uid}, opts \\ []) do
    proc = Keyword.get(opts, :proc_root, "/proc")
    server_uid = Keyword.get_lazy(opts, :server_uid, &own_uid/0)
    server_pid = Keyword.get_lazy(opts, :server_pid, fn -> String.to_integer(System.pid()) end)

    cond do
      uid != server_uid ->
        {:error, :foreign_uid}

      not is_integer(pid) or pid <= 0 ->
        {:error, :unknown_peer}

      true ->
        with :ok <- check_ancestry(proc, pid, server_pid, 0) do
          server_cgroup = Keyword.get_lazy(opts, :server_cgroup, fn -> own_cgroup(proc) end)
          check_cgroup(proc, pid, server_cgroup)
        end
    end
  end

  @doc "Operator-facing text for a refusal reason."
  @spec describe(reason() | atom()) :: String.t()
  def describe(:foreign_uid), do: "the connecting process belongs to a different Unix user"

  def describe(:spawned_by_arbiter),
    do:
      "the connecting process was started by the Arbiter server (a worker, reviewer or " <>
        "session, or something one of them ran); those get their tokens at dispatch"

  def describe(:in_arbiter_cgroup),
    do:
      "the connecting process is inside the Arbiter server's service cgroup, where every " <>
        "worker it spawns runs"

  def describe(:peer_unreadable),
    do: "the connecting process could not be inspected through /proc, so it is refused"

  def describe(:unknown_peer), do: "the kernel reported no process for the connection"
  def describe(:no_peercred), do: "peer credentials are unavailable on this platform"
  def describe(other), do: "refused (#{inspect(other)})"

  # ---- socket location ---------------------------------------------------

  @doc """
  Directory the operator socket lives in: `/run/user/<uid>/arbiter` when the
  host has a per-user runtime dir (systemd hosts; the agy jail blanks it),
  else `<data_dir>/run` (`~/.arbiter/run`, which `Arbiter.Worker.Jail`
  masks explicitly). `ARB_OPERATOR_SOCKET` overrides the whole path, see
  `socket_path/1`.

  Both the server and the `arb` CLI derive the path the same way from the
  uid, never from `XDG_RUNTIME_DIR`, so a shell that lacks the variable
  still finds the socket.
  """
  @spec socket_dir() :: String.t()
  def socket_dir do
    case System.get_env("ARB_OPERATOR_SOCKET") do
      path when is_binary(path) and path != "" -> Path.dirname(Path.expand(path))
      _ -> default_dir()
    end
  end

  @doc "The operator socket path for the server listening on HTTP `port`."
  @spec socket_path(non_neg_integer()) :: String.t()
  def socket_path(port) when is_integer(port) do
    case System.get_env("ARB_OPERATOR_SOCKET") do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(default_dir(), "operator-#{port}.sock")
    end
  end

  defp default_dir do
    runtime = own_uid() && "/run/user/#{own_uid()}"

    if runtime && File.dir?(runtime) do
      Path.join(runtime, "arbiter")
    else
      Path.join(Application.get_env(:arbiter, :data_dir, Path.expand("~/.arbiter")), "run")
    end
  end

  # ---- helpers -------------------------------------------------------------

  @doc "Decode a Linux `struct ucred` (the `SO_PEERCRED` payload)."
  @spec parse_peercred(binary()) :: {:ok, peer()} | :error
  def parse_peercred(<<pid::native-signed-32, uid::native-signed-32, gid::native-signed-32>>),
    do: {:ok, %{pid: pid, uid: uid, gid: gid}}

  def parse_peercred(_), do: :error

  @doc """
  The server's cgroup path from the contents of `/proc/<pid>/cgroup` when it
  is a dedicated systemd service (last segment ends in `.service`), else
  `nil`. Prefers the unified (v2) hierarchy and falls back to v1's
  `name=systemd` line.
  """
  @spec dedicated_cgroup(String.t()) :: String.t() | nil
  def dedicated_cgroup(contents) do
    case cgroup_path(contents) do
      path when is_binary(path) ->
        if String.ends_with?(path, ".service"), do: path, else: nil

      nil ->
        nil
    end
  end

  defp cgroup_path(contents) do
    entries =
      contents
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&cgroup_entry/1)

    unified = Enum.find_value(entries, fn {id, c, p} -> id == "0" and c == "" and p end)
    v1 = Enum.find_value(entries, fn {_id, c, p} -> c == "name=systemd" and p end)

    cond do
      is_binary(unified) and unified != "/" -> unified
      is_binary(v1) -> v1
      true -> unified
    end
  end

  defp cgroup_entry(line) do
    case String.split(line, ":", parts: 3) do
      [id, controllers, path] -> [{id, controllers, path}]
      _ -> []
    end
  end

  defp check_ancestry(_proc, pid, server_pid, _depth) when pid == server_pid,
    do: {:error, :spawned_by_arbiter}

  defp check_ancestry(_proc, pid, _server_pid, _depth) when pid in [0, 1], do: :ok

  defp check_ancestry(_proc, _pid, _server_pid, depth) when depth > @max_depth,
    do: {:error, :peer_unreadable}

  defp check_ancestry(proc, pid, server_pid, depth) do
    case ppid(proc, pid) do
      {:ok, parent} -> check_ancestry(proc, parent, server_pid, depth + 1)
      :error -> {:error, :peer_unreadable}
    end
  end

  # `/proc/<pid>/stat` is "pid (comm) state ppid …"; comm may itself contain
  # spaces and ")", so split after the *last* ")".
  defp ppid(proc, pid) do
    with {:ok, stat} <- File.read(Path.join([proc, Integer.to_string(pid), "stat"])),
         [_, _ | _] = parts <- String.split(stat, ")"),
         [_state, ppid | _] <- parts |> List.last() |> String.split(),
         {n, ""} <- Integer.parse(ppid) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp check_cgroup(_proc, _pid, nil), do: :ok

  defp check_cgroup(proc, pid, server_cgroup) do
    case File.read(Path.join([proc, Integer.to_string(pid), "cgroup"])) do
      {:ok, contents} ->
        peer = cgroup_path(contents)

        if peer == server_cgroup or
             (is_binary(peer) and String.starts_with?(peer, server_cgroup <> "/")),
           do: {:error, :in_arbiter_cgroup},
           else: :ok

      {:error, _} ->
        {:error, :peer_unreadable}
    end
  end

  defp own_cgroup(proc) do
    case File.read(Path.join([proc, "self", "cgroup"])) do
      {:ok, contents} -> dedicated_cgroup(contents)
      {:error, _} -> nil
    end
  end

  defp own_uid do
    case File.stat("/proc/self") do
      {:ok, %{uid: uid}} -> uid
      _ -> nil
    end
  end
end
