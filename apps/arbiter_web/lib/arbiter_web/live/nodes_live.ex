defmodule ArbiterWeb.NodesLive do
  @moduledoc """
  The operator's view of remote worker nodes (RW7,
  `docs/design/remote-workers.md` §14): `/nodes` lists the fleet, `/nodes/:id`
  is one node.

  ## The list

  One row per node, with the primary first as a `local` row. Each row shows its
  state, health, agent version, **live/max** capacity and last heartbeat, and
  the whole cap story: the node's own **suggestion**, the operator's
  **override** (an inline form, up or down; `local` may go to 0) and any
  **ceiling** the node's owner configured on the node, which the override
  cannot beat. The header sums `local + Σ remote caps` against
  `conductor.max_concurrent` and warns when the ceiling sits below the sum (or
  far above it). A local cap of 0 keeps a warning up: work that can only run
  here — reviewers, fix and conflict passes, agy/codex, research — waits.

  Everything comes from `Arbiter.Nodes.Overview`; the page re-reads on every
  `Arbiter.Nodes.topic/0` broadcast and on a slow timer, so a drain from
  `arb node` or a node connecting shows without a reload.

  ## Add node

  `#add-node-button` opens `#add-node-modal`. Submitting mints a join token
  (the same `Arbiter.Nodes.mint_join_token/2` and rate limit as
  `arb node add`) and shows the one-liner (`#join-command`, no secret in it) and,
  separately, the token (`#join-token`, shown once), each with a copy button, a
  countdown, and "Waiting for node…" until the node enrols (the `nodes` topic's
  `{:node_enrolled, _, join_token_id}`). Closing the modal drops the token from
  the socket's assigns.

  ## Actions

  Drain / undrain, upgrade (a connected node that is behind or ahead), revoke
  and remove (revoked nodes only). Each goes through `Arbiter.Nodes`, which
  writes the `NodeEvent`, attributed to `operator:dashboard`. The dashboard is
  operator-only (`:dashboard_auth`), so there is no second gate here.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{JoinScript, Overview, RateLimit}
  alias Arbiter.Settings
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Forms

  @refresh_ms 10_000
  # What `Arbiter.Nodes.Session` and `Arbiter.Nodes` broadcast on the topic.
  @node_events [:node_state, :node_connection, :node_draining, :node_lost, :node_revoked]
  @tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
      :timer.send_interval(@refresh_ms, :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Nodes")
     |> assign(:add, nil)
     |> assign(:cap_errors, %{})
     |> assign(:node_id, nil)
     |> assign(:node, nil)
     |> assign(:node_row, nil)
     |> assign(:events, [])
     |> assign(:overview, nil)
     |> assign(:public_url, nil)
     |> stream_configure(:nodes, dom_id: &"node-#{&1.id}")
     |> stream(:nodes, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Nodes.find_node(id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/nodes")}

      node ->
        {:noreply, socket |> assign(:node_id, node.id) |> load()}
    end
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, socket |> assign(:node_id, nil) |> load()}

  # ---- loading ---------------------------------------------------------------

  defp load(socket) do
    overview = Overview.build()
    id = socket.assigns.node_id
    node = id && Nodes.get_node(id)

    socket
    |> assign(:overview, overview)
    |> assign(:public_url, Settings.nodes_public_url())
    |> assign(:node, node)
    |> assign(:node_row, node && Enum.find(overview.nodes, &(&1.id == node.id)))
    |> assign(:events, if(node, do: Enum.reverse(Nodes.events(node_id: node.id)), else: []))
    |> stream(:nodes, [overview.local | overview.nodes], reset: true)
  end

  # A node removed from under the detail page (here or by `arb node remove`).
  defp refresh(%{assigns: %{node_id: id}} = socket) when is_binary(id) do
    case Nodes.get_node(id) do
      nil -> push_navigate(socket, to: ~p"/nodes")
      _ -> load(socket)
    end
  end

  defp refresh(socket), do: load(socket)

  # ---- messages --------------------------------------------------------------

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:node_enrolled, _id, join_token_id}, socket) do
    {:noreply, socket |> enrolled(join_token_id) |> refresh()}
  end

  def handle_info(:tick, %{assigns: %{add: %{minted: %{}} = add}} = socket) do
    if add.status == :waiting, do: Process.send_after(self(), :tick, @tick_ms)
    {:noreply, assign(socket, :add, %{add | now: DateTime.utc_now()})}
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  # Every broadcast on the `nodes` topic (state, drain, revoke, lost, connection).
  def handle_info(msg, socket) when is_tuple(msg) and elem(msg, 0) in @node_events do
    {:noreply, refresh(socket)}
  end

  # The coordinator-inbox broadcasts every live_session LiveView receives.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp enrolled(%{assigns: %{add: %{minted: %{join_token_id: id}} = add}} = socket, id),
    do: assign(socket, :add, %{add | status: :connected})

  defp enrolled(socket, _join_token_id), do: socket

  # ---- events ----------------------------------------------------------------

  @impl true
  def handle_event("open_add", _params, socket) do
    {:noreply, assign(socket, :add, new_add())}
  end

  def handle_event("close_add", _params, socket), do: {:noreply, assign(socket, :add, nil)}

  def handle_event("mint", params, %{assigns: %{add: %{} = add}} = socket) do
    form = to_form(Map.take(params, ~w(name labels max_workers ttl_minutes)), as: :add)

    case mint(params) do
      {:ok, minted} ->
        Process.send_after(self(), :tick, @tick_ms)

        {:noreply,
         assign(socket, :add, %{add | form: form, error: nil, minted: minted, status: :waiting})}

      {:error, message} ->
        {:noreply, assign(socket, :add, %{add | form: form, error: message})}
    end
  end

  def handle_event("mint", _params, socket), do: {:noreply, socket}

  def handle_event("set_cap", %{"node_id" => id, "max_workers" => raw}, socket) do
    case set_cap(id, String.trim(raw)) do
      :ok ->
        {:noreply, socket |> update(:cap_errors, &Map.delete(&1, id)) |> refresh()}

      {:error, message} ->
        {:noreply, socket |> update(:cap_errors, &Map.put(&1, id, message)) |> refresh()}
    end
  end

  def handle_event("drain", %{"id" => id}, socket),
    do: act(socket, id, &Nodes.drain/2, "draining")

  def handle_event("undrain", %{"id" => id}, socket),
    do: act(socket, id, &Nodes.undrain/2, "active")

  def handle_event("revoke", %{"id" => id}, socket),
    do: act(socket, id, &Nodes.revoke/2, "revoked")

  def handle_event("upgrade", %{"id" => id}, socket) do
    case node_ref(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown node.")}

      node ->
        case Nodes.upgrade(node, actor()) do
          {:ok, %{version: v}} ->
            {:noreply,
             socket |> put_flash(:info, "#{node.name}: upgrading to #{v}.") |> refresh()}

          {:error, :offline} ->
            {:noreply, put_flash(socket, :error, "#{node.name} is not connected.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not upgrade #{node.name}: #{reason}.")}
        end
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case node_ref(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown node.")}

      node ->
        case Nodes.remove(node, actor()) do
          :ok ->
            socket = put_flash(socket, :info, "Removed #{node.name}.")

            if socket.assigns.node_id == node.id,
              do: {:noreply, push_navigate(socket, to: ~p"/nodes")},
              else: {:noreply, refresh(socket)}

          {:error, :not_revoked} ->
            {:noreply, put_flash(socket, :error, "Revoke #{node.name} before removing it.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove #{node.name}.")}
        end
    end
  end

  defp act(socket, id, fun, _expected) do
    case node_ref(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown node.")}

      node ->
        case fun.(node, actor()) do
          {:ok, _} -> {:noreply, refresh(socket)}
          {:error, :revoked} -> {:noreply, put_flash(socket, :error, "#{node.name} is revoked.")}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not update #{node.name}.")}
        end
    end
  end

  defp node_ref(id) when is_binary(id), do: Nodes.find_node(id)
  defp node_ref(_), do: nil

  defp actor, do: Actor.operator("dashboard")

  # ---- add node --------------------------------------------------------------

  defp new_add do
    %{
      form:
        to_form(
          %{
            "name" => "",
            "labels" => "",
            "max_workers" => "",
            "ttl_minutes" => Integer.to_string(Settings.nodes_join_token_ttl_minutes())
          },
          as: :add
        ),
      error: nil,
      minted: nil,
      status: :form,
      now: DateTime.utc_now()
    }
  end

  defp mint(params) do
    with {:ok, url} <- public_url(),
         {:ok, opts} <- mint_opts(params),
         :ok <- mint_limit(),
         {:ok, %{token: token, join_token: row}} <- Nodes.mint_join_token(opts, actor()) do
      {:ok,
       %{
         token: token,
         one_liner: JoinScript.one_liner(url),
         expires_at: row.expires_at,
         join_token_id: row.id,
         name: row.name
       }}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, :invalid_name} -> {:error, name_message()}
      {:error, :invalid_ttl} -> {:error, "The lifetime must be between 1 minute and 24 hours."}
      {:error, {:rate_limited, s}} -> {:error, "Too many tokens minted; try again in #{s}s."}
      {:error, _} -> {:error, "Could not mint a join token."}
    end
  end

  defp public_url do
    case Settings.nodes_public_url() do
      nil -> {:error, "nodes.public_url is not set."}
      url -> {:ok, url}
    end
  end

  defp mint_limit, do: RateLimit.check(:mint, Actor.label(actor()))

  defp mint_opts(params) do
    with {:ok, max} <-
           optional_int(
             params["max_workers"],
             1,
             "Max workers must be a whole number, 1 or more."
           ),
         {:ok, ttl} <-
           optional_int(
             params["ttl_minutes"],
             1,
             "The lifetime must be a whole number of minutes."
           ) do
      name = blank_to_nil(params["name"])

      if is_nil(name) or Nodes.valid_name?(name) do
        {:ok,
         Enum.reject(
           [
             name: name,
             labels: labels(params["labels"]),
             max_workers: max,
             ttl_seconds: ttl && ttl * 60
           ],
           fn {_k, v} -> is_nil(v) or v == [] end
         )}
      else
        {:error, name_message()}
      end
    end
  end

  defp name_message,
    do: "A name may only contain A-Za-z0-9._=:/@- (1-128 characters) and cannot be \"local\"."

  defp labels(nil), do: []

  defp labels(text) do
    text |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_int(raw, min, message) do
    case blank_to_nil(raw) do
      nil -> {:ok, nil}
      text -> parse_int(text, min, message)
    end
  end

  defp parse_int(text, min, message) do
    case Integer.parse(text) do
      {n, ""} when n >= min -> {:ok, n}
      _ -> {:error, message}
    end
  end

  # ---- caps ------------------------------------------------------------------

  defp set_cap("local", raw) do
    with {:ok, n} <- optional_int(raw, 0, "The local cap must be a whole number, 0 or more."),
         {:ok, _} <- Nodes.set_local_max_workers(n, actor()) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _} -> {:error, "Could not set the local cap."}
    end
  end

  defp set_cap(id, raw) do
    with %{} = node <- node_ref(id) || {:error, "Unknown node."},
         {:ok, n} <-
           optional_int(
             raw,
             1,
             "A cap must be a whole number, 1 or more. Drain a node to stop it."
           ),
         {:ok, _} <- Nodes.update_node(node, %{max_workers: n}, actor()) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, :revoked} -> {:error, "The node is revoked."}
      {:error, _} -> {:error, "Could not set the cap."}
    end
  end

  # ---- view helpers ----------------------------------------------------------

  defp ago(nil), do: "never"

  defp ago(%DateTime{} = at) do
    case max(DateTime.diff(DateTime.utc_now(), at), 0) do
      s when s < 60 -> "#{s}s ago"
      s when s < 3600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end

  defp countdown(%DateTime{} = expires_at, %DateTime{} = now) do
    case DateTime.diff(expires_at, now) do
      s when s <= 0 -> "expired"
      s -> "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
  end

  defp expired?(%{minted: %{expires_at: at}, now: now}), do: DateTime.compare(at, now) != :gt

  defp state_class(:online),
    do: "bg-[color-mix(in_oklch,var(--arb-live)_14%,transparent)] text-[var(--arb-live)]"

  defp state_class(state) when state in [:suspect, :draining],
    do: "bg-[var(--arb-attention-wash,var(--arb-panel))] text-[var(--arb-attention)]"

  defp state_class(:revoked), do: "bg-[var(--arb-fail-wash)] text-[var(--arb-fail-text)]"
  defp state_class(_), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"

  defp health_class(health) when health in [:ready, nil], do: "text-[var(--text-secondary)]"
  defp health_class(_), do: "text-[var(--arb-attention)]"

  defp bound?(%{override: o, ceiling: c}) when is_integer(o) and is_integer(c), do: o > c
  defp bound?(_), do: false

  defp upgradeable?(row),
    do: row.state in [:online, :suspect] and row.health in [:outdated, :ahead]

  defp cap_error(errors, id), do: Map.get(errors, id)

  # ---- render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      quota_on_exhaustion={@quota_on_exhaustion}
      open_epic_count={@open_epic_count}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div id="nodes-page" class="p-4 sm:p-6 max-w-7xl mx-auto space-y-5">
        <%= if @live_action == :show and @node do %>
          <.detail node={@node} row={@node_row} events={@events} />
        <% else %>
          <.fleet
            overview={@overview}
            streams={@streams}
            public_url={@public_url}
            cap_errors={@cap_errors}
          />
        <% end %>

        <.add_modal :if={@add} add={@add} />
      </div>
    </Layouts.app>
    """
  end

  attr :overview, :map, required: true
  attr :streams, :any, required: true
  attr :public_url, :string, default: nil
  attr :cap_errors, :map, required: true

  defp fleet(assigns) do
    ~H"""
    <Domain.index_header
      icon="hero-server-stack"
      title="Nodes"
      count={length(@overview.nodes)}
      subtitle="Machines that run workers for this install, and the primary's own share."
      stack_on_mobile
    >
      <:actions>
        <Core.button
          id="add-node-button"
          variant="primary"
          size="sm"
          phx-click="open_add"
          disabled={is_nil(@public_url)}
        >
          <:icon><Core.icon name="hero-plus" size={13} /></:icon>
          Add node
        </Core.button>
      </:actions>
    </Domain.index_header>

    <div
      :if={is_nil(@public_url)}
      id="nodes-public-url-missing"
      class="rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--arb-panel)] px-3 py-2 text-[12px] text-[var(--text-secondary)]"
    >
      Set <code class="font-[family-name:var(--font-mono)]">nodes.public_url</code>
      (<code class="font-[family-name:var(--font-mono)]">arb settings set nodes.public_url https://…</code>)
      before adding a node: it is the address the join script and the agent dial.
    </div>

    <div
      id="nodes-capacity-summary"
      class="flex flex-wrap items-baseline gap-x-4 gap-y-1 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--arb-panel-alt)] px-3 py-2 text-[12.5px] text-[var(--text-secondary)]"
    >
      <span>
        local <b class="tabular-nums text-[var(--text-title)]">{@overview.local.max}</b>
        + nodes
        <b class="tabular-nums text-[var(--text-title)]">{@overview.total - @overview.local.max}</b>
        = <b class="tabular-nums text-[var(--text-title)]">{@overview.total}</b>
      </span>
      <span>
        against <code class="font-[family-name:var(--font-mono)]">conductor.max_concurrent</code>
        = <b class="tabular-nums text-[var(--text-title)]">{@overview.ceiling}</b>
      </span>
    </div>

    <.warning :if={:local_cap_zero in @overview.warnings} id="nodes-local-cap-warning">
      The local cap is 0: nothing runs on this machine. Work that can only run here
      (reviewers, fix and conflict passes, agy/codex runs, research) will wait until a local slot opens.
    </.warning>
    <.warning :if={:ceiling_below_total in @overview.warnings} id="nodes-ceiling-warning">
      conductor.max_concurrent ({@overview.ceiling}) is below the {@overview.total} slots the caps add up to:
      the extra capacity will sit idle. Raise it if you want it used.
    </.warning>
    <.warning :if={:ceiling_far_above_total in @overview.warnings} id="nodes-ceiling-high-warning">
      conductor.max_concurrent ({@overview.ceiling}) is far above the {@overview.total} slots the caps add up to:
      the board will plan more work than any machine can start.
    </.warning>

    <div class="overflow-x-auto rounded-[var(--radius-field)] border border-solid border-[var(--border-default)]">
      <table id="nodes-table" class="w-full text-[12.5px]">
        <thead class="text-left text-[10.5px] uppercase tracking-wide text-[var(--text-label)]">
          <tr class="border-b border-[var(--border-default)]">
            <th class="px-3 py-2 font-medium">Node</th>
            <th class="px-3 py-2 font-medium">State</th>
            <th class="px-3 py-2 font-medium">Health</th>
            <th class="px-3 py-2 font-medium">Version</th>
            <th class="px-3 py-2 font-medium text-right">Live / max</th>
            <th class="px-3 py-2 font-medium text-right">Suggested</th>
            <th class="px-3 py-2 font-medium">Override</th>
            <th class="px-3 py-2 font-medium text-right">Ceiling</th>
            <th class="px-3 py-2 font-medium">Last heartbeat</th>
            <th class="px-3 py-2 font-medium"><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody id="nodes-rows" phx-update="stream">
          <.node_row
            :for={{dom_id, row} <- @streams.nodes}
            id={dom_id}
            row={row}
            cap_error={cap_error(@cap_errors, row.id)}
          />
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :cap_error, :string, default: nil

  defp node_row(assigns) do
    ~H"""
    <tr
      id={@id}
      class="border-b border-[var(--border-default)] last:border-b-0 align-top transition-colors hover:bg-[var(--arb-panel-alt)]"
    >
      <td class="px-3 py-2">
        <%= if @row.kind == :local do %>
          <span class="font-medium text-[var(--text-title)]">local</span>
          <span class="block text-[10.5px] text-[var(--text-label)]">this machine (the primary)</span>
        <% else %>
          <.link
            navigate={~p"/nodes/#{@row.id}"}
            class="font-medium text-[var(--text-link)] hover:text-[var(--text-title)]"
          >
            {@row.name}
          </.link>
          <span :if={@row.labels != []} class="block text-[10.5px] text-[var(--text-label)]">
            {Enum.join(@row.labels, ", ")}
          </span>
        <% end %>
      </td>
      <td class="px-3 py-2">
        <span
          data-role="state"
          class={[
            "px-1.5 py-px rounded-[var(--radius-field)] text-[10.5px] font-medium",
            state_class(@row.state)
          ]}
        >
          {@row.state}
        </span>
      </td>
      <td class="px-3 py-2">
        <span :if={@row.kind != :local} data-role="health" class={health_class(@row.health)}>
          {@row.health || "—"}
        </span>
      </td>
      <td class="px-3 py-2 font-[family-name:var(--font-mono)] text-[11.5px]" data-role="version">
        {@row.agent_version || "—"}
      </td>
      <td
        class="px-3 py-2 text-right tabular-nums font-[family-name:var(--font-mono)]"
        data-role="capacity"
      >
        {@row.live}/{@row.max || "?"}
      </td>
      <td
        class="px-3 py-2 text-right tabular-nums font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
        data-role="suggested"
      >
        {@row.suggested || "—"}
      </td>
      <td class="px-3 py-2">
        <form
          :if={@row.state != :revoked}
          id={"cap-form-#{@row.id}"}
          phx-submit="set_cap"
          class="flex items-center gap-1.5"
        >
          <input type="hidden" name="node_id" value={@row.id} />
          <Forms.input
            name="max_workers"
            id={"cap-input-#{@row.id}"}
            value={@row.override}
            size="sm"
            placeholder="default"
            inputmode="numeric"
            aria-label={"Override the worker cap of #{@row.name}"}
            class="w-[88px]"
          />
          <Core.button type="submit" size="sm" variant="ghost">Set</Core.button>
        </form>
        <span
          :if={bound?(@row)}
          data-role="cap-bound"
          class="block mt-1 text-[10.5px] text-[var(--arb-attention)]"
        >
          above the node's ceiling of {@row.ceiling}; the ceiling wins
        </span>
        <span
          :if={@cap_error}
          id={"cap-error-#{@row.id}"}
          class="block mt-1 text-[11px] text-[var(--arb-fail-text)]"
        >
          {@cap_error}
        </span>
      </td>
      <td
        class="px-3 py-2 text-right tabular-nums font-[family-name:var(--font-mono)] text-[var(--text-secondary)]"
        data-role="ceiling"
      >
        {@row.ceiling || "—"}
      </td>
      <td class="px-3 py-2 text-[var(--text-secondary)]" data-role="heartbeat">
        <%= if @row.kind == :local do %>
          —
        <% else %>
          {ago(@row.last_heartbeat_at)}
        <% end %>
      </td>
      <td class="px-3 py-2">
        <.actions :if={@row.kind != :local} row={@row} />
      </td>
    </tr>
    """
  end

  attr :row, :map, required: true

  defp actions(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-end gap-1.5">
      <Core.button
        :if={@row.state not in [:draining, :revoked]}
        id={"drain-#{@row.id}"}
        size="sm"
        phx-click="drain"
        phx-value-id={@row.id}
      >
        Drain
      </Core.button>
      <Core.button
        :if={@row.state == :draining}
        id={"undrain-#{@row.id}"}
        size="sm"
        phx-click="undrain"
        phx-value-id={@row.id}
      >
        Undrain
      </Core.button>
      <Core.button
        :if={upgradeable?(@row)}
        id={"upgrade-#{@row.id}"}
        size="sm"
        phx-click="upgrade"
        phx-value-id={@row.id}
      >
        Upgrade
      </Core.button>
      <Core.button
        :if={@row.state != :revoked}
        id={"revoke-#{@row.id}"}
        size="sm"
        variant="danger"
        phx-click="revoke"
        phx-value-id={@row.id}
        data-confirm={"Revoke #{@row.name}? Its credential stops working and it is disconnected."}
      >
        Revoke
      </Core.button>
      <Core.button
        :if={@row.state == :revoked}
        id={"remove-#{@row.id}"}
        size="sm"
        variant="danger"
        phx-click="remove"
        phx-value-id={@row.id}
        data-confirm={"Remove #{@row.name}? Its event history is kept."}
      >
        Remove
      </Core.button>
    </div>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  defp warning(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      class="flex items-start gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--arb-attention)] bg-[var(--arb-panel)] px-3 py-2 text-[12px] text-[var(--arb-attention)]"
    >
      <Core.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
      <span class="min-w-0 break-words">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  # ---- add node modal --------------------------------------------------------

  attr :add, :map, required: true

  defp add_modal(assigns) do
    ~H"""
    <div
      id="add-node-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="add-node-title"
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4 sm:pt-[12vh]"
    >
      <div class="w-full max-w-xl rounded-[var(--radius-card,8px)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] p-5 shadow-xl space-y-4">
        <div class="flex items-center justify-between gap-3">
          <h2 id="add-node-title" class="m-0 text-[16px] font-semibold text-[var(--text-title)]">
            Add node
          </h2>
          <Core.button id="add-node-close" variant="ghost" size="sm" phx-click="close_add">
            Close
          </Core.button>
        </div>

        <%= if @add.minted do %>
          <div class="space-y-4">
            <div>
              <p class="m-0 mb-1.5 text-[12px] text-[var(--text-secondary)]">
                1. On the new machine, as the user that will own the node (not root), run this.
                It contains no secret:
              </p>
              <div class="flex items-start gap-2">
                <code
                  id="join-command"
                  class="min-w-0 flex-1 break-all rounded-[var(--radius-field)] bg-[var(--surface-field)] px-2.5 py-2 text-[12px] font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]"
                >
                  {@add.minted.one_liner}
                </code>
                <Core.copy_id
                  id={@add.minted.one_liner}
                  dom_id="copy-join-command"
                  label="Copy the join command"
                />
              </div>
            </div>
            <div>
              <p class="m-0 mb-1.5 text-[12px] text-[var(--text-secondary)]">
                2. When the script asks, enter this token. It works once and is shown only here:
              </p>
              <div class="flex items-start gap-2">
                <code
                  id="join-token"
                  class="min-w-0 flex-1 break-all rounded-[var(--radius-field)] bg-[var(--surface-field)] px-2.5 py-2 text-[12px] font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]"
                >
                  {@add.minted.token}
                </code>
                <Core.copy_id
                  id={@add.minted.token}
                  dom_id="copy-join-token"
                  label="Copy the join token"
                />
              </div>
            </div>
            <div class="flex items-center justify-between gap-3 text-[12px]">
              <span id="join-status" class="text-[var(--text-secondary)]">
                <%= cond do %>
                  <% @add.status == :connected -> %>
                    <span class="text-[var(--arb-live)] font-medium">Connected</span>
                    — the node enrolled.
                  <% expired?(@add) -> %>
                    Expired. Close this and add the node again.
                  <% true -> %>
                    Waiting for node…
                <% end %>
              </span>
              <span
                :if={@add.status != :connected}
                id="join-countdown"
                class="tabular-nums font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {countdown(@add.minted.expires_at, @add.now)}
              </span>
            </div>
          </div>
        <% else %>
          <.form for={@add.form} id="add-node-form" phx-submit="mint" class="space-y-3">
            <Forms.input
              name="name"
              id="add-node-name"
              label="Name"
              hint="optional"
              value={@add.form["name"].value}
              placeholder="gpu-box-1"
            />
            <Forms.input
              name="labels"
              id="add-node-labels"
              label="Labels"
              hint="comma separated"
              value={@add.form["labels"].value}
              placeholder="zone=a, gpu"
            />
            <div class="grid grid-cols-2 gap-3">
              <Forms.input
                name="max_workers"
                id="add-node-max-workers"
                label="Max workers"
                hint="optional"
                value={@add.form["max_workers"].value}
                inputmode="numeric"
              />
              <Forms.input
                name="ttl_minutes"
                id="add-node-ttl"
                label="Token lifetime"
                hint="minutes"
                value={@add.form["ttl_minutes"].value}
                inputmode="numeric"
              />
            </div>
            <p
              :if={@add.error}
              id="add-node-error"
              role="alert"
              class="m-0 text-[12px] text-[var(--arb-fail-text)]"
            >
              {@add.error}
            </p>
            <div class="flex justify-end">
              <Core.button id="add-node-submit" type="submit" variant="primary">
                Issue token
              </Core.button>
            </div>
          </.form>
        <% end %>
      </div>
    </div>
    """
  end

  # ---- detail ----------------------------------------------------------------

  attr :node, :map, required: true
  attr :row, :map, default: nil
  attr :events, :list, required: true

  defp detail(assigns) do
    ~H"""
    <div id="node-detail" class="space-y-5">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <.link
            navigate={~p"/nodes"}
            class="text-[10.5px] text-[var(--text-link)] hover:text-[var(--text-title)]"
          >
            ← Nodes
          </.link>
          <h1 class="mt-1.5 mb-0 flex items-center gap-2 text-[24px] font-semibold leading-[1.2] text-[var(--text-title)]">
            {@node.name}
            <span
              :if={@row}
              data-role="state"
              class={[
                "px-1.5 py-px rounded-[var(--radius-field)] text-[10.5px] font-medium",
                state_class(@row.state)
              ]}
            >
              {@row.state}
            </span>
          </h1>
          <code class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
            {@node.id}
          </code>
        </div>
        <.actions :if={@row} row={@row} />
      </div>

      <div :if={@row} class="grid gap-4 md:grid-cols-2">
        <section class="rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] p-4 space-y-1.5 text-[12.5px]">
          <h2 class="m-0 mb-2 text-[13px] font-semibold text-[var(--text-title)]">Agent</h2>
          <.fact label="health" value={@row.health || "not connected"} />
          <.fact label="agent version" value={@row.agent_version || "—"} />
          <.fact label="primary version" value={@row.server_version} />
          <.fact label="protocol" value={@row.proto || "—"} />
          <.fact label="backend" value={@row.caps["backend"] || "—"} />
          <.fact
            label="labels"
            value={if(@row.labels == [], do: "—", else: Enum.join(@row.labels, ", "))}
          />
          <.fact label="last heartbeat" value={ago(@row.last_heartbeat_at)} />
          <.fact label="enrolled" value={Calendar.strftime(@node.enrolled_at, "%Y-%m-%d %H:%M UTC")} />
        </section>

        <section
          id="node-capacity"
          class="rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] p-4 space-y-1.5 text-[12.5px]"
        >
          <h2 class="m-0 mb-2 text-[13px] font-semibold text-[var(--text-title)]">Capacity</h2>
          <.fact label="suggested (from the node)" value={@row.suggested || "—"} />
          <.fact label="override (yours)" value={@row.override || "none"} />
          <.fact label="ceiling (set on the node)" value={@row.ceiling || "none"} />
          <.fact label="effective max" value={@row.max || "?"} />
          <.fact label="live" value={@row.live} />
          <.fact
            label="pinned to workspaces"
            value={if @row.workspace_ids == [], do: "any", else: Enum.join(@row.workspace_ids, ", ")}
          />
        </section>
      </div>

      <section
        id="node-live-runs"
        class="rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] p-4 text-[12.5px]"
      >
        <h2 class="m-0 mb-2 text-[13px] font-semibold text-[var(--text-title)]">Live runs</h2>
        <p :if={is_nil(@row) or @row.run_ids == []} class="m-0 text-[var(--text-secondary)]">
          No runs on this node.
        </p>
        <ul :if={@row && @row.run_ids != []} class="m-0 list-none p-0 space-y-1">
          <li :for={run_id <- @row.run_ids}>
            <.link
              navigate={~p"/workers/history/#{run_id}"}
              class="font-[family-name:var(--font-mono)] text-[var(--text-link)] hover:text-[var(--text-title)]"
            >
              {String.slice(run_id, 0, 8)}
            </.link>
          </li>
        </ul>
      </section>

      <section class="rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] p-4 text-[12.5px]">
        <h2 class="m-0 mb-2 text-[13px] font-semibold text-[var(--text-title)]">Events</h2>
        <ul id="node-events" class="m-0 list-none p-0 space-y-1">
          <li :for={e <- @events} class="flex flex-wrap gap-x-3 text-[var(--text-secondary)]">
            <span class="tabular-nums font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--text-label)]">
              {Calendar.strftime(e.at, "%Y-%m-%d %H:%M:%S")}
            </span>
            <span class="font-medium text-[var(--text-title)]">{e.kind}</span>
            <span>{e.actor || "—"}</span>
            <span :if={e.detail != %{}} class="font-[family-name:var(--font-mono)] text-[11.5px]">
              {Jason.encode!(e.detail)}
            </span>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex justify-between gap-4">
      <span class="text-[var(--text-label)]">{@label}</span>
      <span class="text-right font-[family-name:var(--font-mono)] text-[var(--arb-text-body)]">
        {@value}
      </span>
    </div>
    """
  end
end
