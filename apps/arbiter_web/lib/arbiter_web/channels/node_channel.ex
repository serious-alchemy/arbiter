defmodule ArbiterWeb.NodeChannel do
  @moduledoc """
  The primary's end of a node agent's connection, topic `node:<node_id>`
  (`docs/design/remote-workers.md` §4.2, §10.1). A thin pipe: everything the
  primary *knows* about the node lives in its `Arbiter.Nodes.Session`, which
  outlives this channel so a socket blip loses nothing (§10.2).

  | node → primary | answer                                                  |
  |----------------|---------------------------------------------------------|
  | `hello`        | attaches this channel to the node's session; pushes `hello_ok` (`boot_epoch`, thresholds, effective `max_workers`, per-run verdicts, health, optional `upgrade`) |
  | `hb`           | pushes `hb_ack` `{seq, boot_epoch}`; a heartbeat before `hello` is replied `error: hello_required` |
  | `run.ready`, `run.refused`, `exit`, binary `stdout` | forwarded to the session's run table (`Arbiter.Nodes.RunStreams`) |
  | `adopt.refused` (bd-4p1vui) | forwarded to the session: the node would not hand a held run to a new Worker |
  | `capacity` (K12, A3) | forwarded to the session (`capacity{ceiling, running, pending, headroom, constrained}`) |
  | `bridge.open`, `bridge.data` (binary), `bridge.credit`, `bridge.recv`, `bridge.close`, `bridge.reset` | forwarded to this connection's `Arbiter.Nodes.Bridge` (RW10), started on the first one; its pushes come back as `{:node_bridge, {:push, event, payload}}` |

  Pushed by the primary: the run protocol (`assign`, `cancel`, `signal`, `ack`,
  `exit_ack`; RW9; `adopt`, bd-4p1vui), `drain` `{on: true | false}`, and `upgrade`
  `{version, sha256}` when the operator asks for it (`Arbiter.Nodes.upgrade/2`). A node can only join its
  own topic.

  ## Closing

  The session sends this channel `{:node_session, {:disconnect, reason}}` and the
  channel ends with `{:shutdown, reason}`:

    * `:revoked`, `:lost` — close the whole socket with
      `Endpoint.broadcast(socket_id, "disconnect", %{})`, which is what makes a
      revoke take effect at once on a live connection (U14). The agent
      reconnects (and, revoked, is refused).
    * `:superseded` — a newer connection took the session over; only *this*
      transport is closed (a broadcast on the shared socket id would close the
      new one too).

  If the session dies for any other reason the channel closes the socket too:
  an agent talking to a session-less channel would heartbeat into the void.
  """

  use Phoenix.Channel

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Bridge, Registry, Session}

  @impl true
  def join("node:" <> id, _params, %Phoenix.Socket{assigns: %{node_id: id}} = socket) do
    {:ok, socket}
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "forbidden"}}

  @impl true
  def handle_in("hello", params, socket) when is_map(params) do
    case Nodes.get_node(socket.assigns.node_id) do
      %Nodes.Node{status: status} = node when status != :revoked ->
        attach(node, params, socket)

      _ ->
        {:stop, {:shutdown, :revoked}, close(socket, :revoked)}
    end
  end

  def handle_in("hb", payload, %{assigns: %{session: session}} = socket) when is_map(payload) do
    case Session.heartbeat(session, payload) do
      {:ok, ack} ->
        push(socket, "hb_ack", ack)
        {:noreply, socket}

      {:error, :revoked} ->
        # The session has stopped and told us; its `{:disconnect, :revoked}` is
        # in our mailbox and closes the socket.
        {:noreply, socket}

      {:error, :no_session} ->
        {:stop, {:shutdown, :session_down}, close(socket, :session_down)}
    end
  end

  def handle_in("hb", _payload, socket),
    do: {:reply, {:error, %{reason: "hello_required"}}, socket}

  # The run protocol (RW9): the node's events go to the session, which owns the
  # run table. A run event before `hello` has no session to go to and is dropped.
<<<<<<< HEAD
  @run_events ~w(run.ready run.refused run.gone exit retained recovered reaped capacity exec.result)
=======
  @run_events ~w(run.ready run.refused run.gone exit retained recovered reaped capacity adopt.refused)
>>>>>>> 3d2bba3c2 (Node adoption handshake: Session.adopt/adoptable/unadopt, agent Run.adopt, adopt.refused, line-boundary stdout acks (bd-4p1vui))

  def handle_in(event, payload, %{assigns: %{session: session}} = socket)
      when event in @run_events and is_map(payload) do
    Session.node_event(session, event, payload)
    {:noreply, socket}
  end

  # A binary push carries a `StdoutFrame`.
  def handle_in("stdout", {:binary, _frame} = payload, %{assigns: %{session: session}} = socket) do
    Session.node_event(session, "stdout", payload)
    {:noreply, socket}
  end

  # The bridge mux (RW10). The streams belong to this connection, not to the
  # session: a blip ends them. A bridge event before `hello` has no session to
  # authorize against and is dropped.
  @bridge_events ~w(bridge.open bridge.data bridge.credit bridge.recv bridge.close bridge.reset)

  def handle_in(event, payload, %{assigns: %{session: session}} = socket)
      when event in @bridge_events do
    socket = ensure_bridge(socket, session)
    Bridge.from_node(socket.assigns.bridge, event, payload)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp ensure_bridge(%{assigns: %{bridge: pid}} = socket, _session) when is_pid(pid), do: socket

  defp ensure_bridge(socket, session) do
    {:ok, pid} =
      Bridge.start(channel: self(), session: session, node_id: socket.assigns.node_id)

    assign(socket, bridge: pid, bridge_ref: Process.monitor(pid))
  end

  defp attach(node, params, socket) do
    params =
      Map.merge(
        %{
          "agent_version" => socket.assigns[:agent_version],
          "proto" => socket.assigns[:proto]
        },
        params
      )

    case Registry.attach(node, self(), params, session_opts()) do
      {:ok, %{pid: pid, hello_ok: hello_ok}} ->
        if old = socket.assigns[:session_ref], do: Process.demonitor(old, [:flush])
        ref = Process.monitor(pid)
        push(socket, "hello_ok", hello_ok)
        {:noreply, assign(socket, session: pid, session_ref: ref)}

      {:error, :revoked} ->
        {:stop, {:shutdown, :revoked}, close(socket, :revoked)}
    end
  end

  # Applies only when a session is *started* here; a test seam for the session's
  # clock and tick (`Arbiter.Nodes.Session`), empty in production.
  defp session_opts, do: Application.get_env(:arbiter_web, :node_session_opts, [])

  @impl true
  def handle_info({:node_session, :drain}, socket) do
    push(socket, "drain", %{"on" => true})
    {:noreply, socket}
  end

  def handle_info({:node_session, :undrain}, socket) do
    push(socket, "drain", %{"on" => false})
    {:noreply, socket}
  end

  # The run protocol, primary → node: `assign`, `cancel`, `signal`, `ack`, `exit_ack`.
  def handle_info({:node_session, {:push, event, payload}}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  # A bridge stream's bytes and credit, primary → node.
  def handle_info({:node_bridge, {:push, event, payload}}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:node_session, {:run_over, run}}, %{assigns: %{bridge: bridge}} = socket)
      when is_pid(bridge) do
    Bridge.run_over(bridge, run)
    {:noreply, socket}
  end

  def handle_info({:node_session, {:run_over, _run}}, socket), do: {:noreply, socket}

  # The bridge ended (the node broke the protocol, or it crashed): its streams
  # are gone, and the node cannot know. Closing the socket tells it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{bridge_ref: ref}} = socket) do
    {:stop, {:shutdown, :bridge_down}, close(socket, :bridge_down)}
  end

  def handle_info({:node_session, {:upgrade, payload}}, socket) do
    push(socket, "upgrade", payload)
    {:noreply, socket}
  end

  def handle_info({:node_session, {:disconnect, reason}}, socket) do
    {:stop, {:shutdown, reason}, close(socket, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{assigns: %{session_ref: ref}} = socket) do
    {:stop, {:shutdown, :session_down}, close(socket, :session_down)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Close the transport. `:superseded` closes only this connection; anything
  # else closes every socket of the node (`NodeSocket.id/1`).
  defp close(socket, :superseded) do
    send(socket.transport_pid, %Phoenix.Socket.Broadcast{
      topic: ArbiterWeb.NodeSocket.id(socket),
      event: "disconnect",
      payload: %{}
    })

    socket
  end

  defp close(socket, _reason) do
    ArbiterWeb.NodeSocket.disconnect(socket.assigns.node_id)
    socket
  end
end
