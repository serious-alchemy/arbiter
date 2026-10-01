defmodule ArbiterWeb.SettingsLive do
  @moduledoc """
  Install-wide settings at `/settings` (bd-3tnoi9).

    * **Scheduler** — the system-wide max concurrent workers and the autopilot
      running/paused switch. Both are mirrored, not moved: the board toolbar
      keeps its own controls over the same data.
    * **Credential watchdog** — which adapters it probes (all / only these /
      none) and its two poll intervals.
    * **Appearance** — the theme switcher (`phx:set-theme`, no JS of its own).
    * **About** — read-only: the version, the install's directories and the
      address the listener is bound to.

  Every save goes through `ArbiterWeb.InstallationSettings`, the code path the
  board shares, and every row shows the value in force next to whether it is an
  override (`Arbiter.Settings.Registry.describe/1`: DB override, else app env,
  else the built-in default). The page also subscribes to
  `Arbiter.Settings.topic/0` and the autopilot's topic, so a change made on the
  board, over REST or from the CLI shows here without a refresh.

  Nothing on this page is a secret, and none of it needs a restart — the
  scheduler and the watchdog read these on their next tick or poll. Provider
  accounts stay on `/providers`.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Board.Autopilot
  alias Arbiter.Settings
  alias Arbiter.Settings.Registry
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Forms
  alias ArbiterWeb.InstallationSettings

  # The page's positive-integer rows: DOM id → registry key. A whitelist, so a
  # forged `setting` param can only ever name one of these.
  @int_settings %{
    "concurrency" => "conductor_system_max_concurrent",
    "interval" => "credential_watchdog_interval_ms",
    "recovery" => "credential_watchdog_recovery_interval_ms"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Settings.topic())
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:errors, %{})
     |> load()}
  end

  @impl true
  def handle_info({:installation_settings_changed, _field}, socket),
    do: {:noreply, load(socket)}

  def handle_info({:board_scheduler, _state}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_int", %{"setting" => id, "value" => raw}, socket)
      when is_map_key(@int_settings, id) do
    case InstallationSettings.save_int(Map.fetch!(@int_settings, id), raw) do
      {:ok, override} ->
        {:noreply,
         socket
         |> clear_error(id)
         |> load()
         |> put_flash(:info, saved_message(id, override))}

      {:error, message} ->
        {:noreply, put_error(socket, id, message)}
    end
  end

  def handle_event("save_adapters", params, socket) do
    case InstallationSettings.save_adapters(params["mode"], params["adapters"]) do
      {:ok, override} ->
        {:noreply,
         socket
         |> clear_error("adapters")
         |> load()
         |> put_flash(:info, saved_message("adapters", override))}

      {:error, message} ->
        {:noreply, put_error(socket, "adapters", message)}
    end
  end

  def handle_event("toggle_autopilot", _params, socket) do
    if InstallationSettings.scheduler_running?() do
      case InstallationSettings.toggle_scheduler() do
        :ok ->
          {:noreply, load(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(:not_running))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ---- state ----------------------------------------------------------------

  defp load(socket) do
    settings = Map.new(Registry.all(), &{&1.key, &1})

    socket
    |> assign(:settings, settings)
    |> assign(:autopilot, load_autopilot())
    |> assign(:agent_types, Arbiter.Agents.valid_agent_types())
  end

  # The scheduler's live answer, with the persisted row as the source of "who
  # and when" until this process has seen a change of its own.
  defp load_autopilot do
    case InstallationSettings.scheduler_status() do
      nil ->
        nil

      status ->
        persisted = Settings.board_autopilot_status()

        %{
          paused?: status.paused?,
          changed_at: status.changed_at || persisted.changed_at,
          changed_by: status.changed_by || persisted.changed_by
        }
    end
  end

  defp put_error(socket, id, message),
    do: assign(socket, :errors, Map.put(socket.assigns.errors, id, message))

  defp clear_error(socket, id),
    do: assign(socket, :errors, Map.delete(socket.assigns.errors, id))

  defp saved_message("concurrency", nil), do: "Max concurrent workers reset to the default."
  defp saved_message("concurrency", n), do: "Max concurrent workers set to #{n}."
  defp saved_message("interval", nil), do: "Watchdog poll interval reset to the default."
  defp saved_message("interval", n), do: "Watchdog poll interval set to #{n} ms."
  defp saved_message("recovery", nil), do: "Watchdog recovery interval reset to the default."
  defp saved_message("recovery", n), do: "Watchdog recovery interval set to #{n} ms."
  defp saved_message("adapters", nil), do: "Watchdog probes every adapter."
  defp saved_message("adapters", []), do: "Watchdog probes no adapter."
  defp saved_message("adapters", list), do: "Watchdog probes #{Enum.join(list, ", ")}."

  # `nil` (all, the default), `[]` (none) and a list (only these) are three
  # different settings — never collapse them.
  defp adapters_mode(nil), do: "all"
  defp adapters_mode([]), do: "none"
  defp adapters_mode(list) when is_list(list), do: "only"

  defp adapters_text([]), do: "none"
  defp adapters_text(list), do: Enum.join(list, ", ")

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:version, ArbiterWeb.VersionHelper.get_version())
      |> assign(:paths, InstallationSettings.paths())
      |> assign(:bind, InstallationSettings.bind_address())

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
      <div id="settings-page" class="p-4 sm:p-6 max-w-5xl mx-auto flex flex-col gap-4">
        <Domain.index_header
          icon="hero-cog-6-tooth"
          title="Settings"
          subtitle="Install-wide settings. Each shows the value in force and whether it is an override; a blank field goes back to the default. Changes apply on the next scheduler tick or watchdog poll — no restart."
        />

        <Core.panel id="settings-scheduler" title="Scheduler" meta="board autopilot">
          <div class="flex flex-col divide-y divide-[var(--border-default)]">
            <.int_row
              id="concurrency"
              label="Max concurrent workers"
              help="The system-wide ceiling on workers the scheduler runs at once. A workspace or provider-account cap lower than this still binds first."
              setting={@settings["conductor_system_max_concurrent"]}
              error={@errors["concurrency"]}
            />
            <.autopilot_row autopilot={@autopilot} />
          </div>
        </Core.panel>

        <Core.panel id="settings-watchdog" title="Credential watchdog" meta="provider logins">
          <div class="flex flex-col divide-y divide-[var(--border-default)]">
            <.adapters_row
              setting={@settings["credential_watchdog_adapters"]}
              error={@errors["adapters"]}
              agent_types={@agent_types}
            />
            <.int_row
              id="interval"
              label="Poll interval"
              unit="ms"
              help="How often the watchdog checks each adapter's credentials."
              setting={@settings["credential_watchdog_interval_ms"]}
              error={@errors["interval"]}
            />
            <.int_row
              id="recovery"
              label="Recovery interval"
              unit="ms"
              help="How often it re-checks an adapter whose credentials have expired."
              setting={@settings["credential_watchdog_recovery_interval_ms"]}
              error={@errors["recovery"]}
            />
          </div>
        </Core.panel>

        <Core.panel id="settings-appearance" title="Appearance">
          <div class="flex items-center justify-between gap-4">
            <div class="min-w-0">
              <div class="text-[12.5px] font-medium text-[var(--text-title)]">Theme</div>
              <p class="m-0 mt-0.5 text-[12px] text-[var(--text-label)]">
                Match the system, or force light or dark. Remembered in this browser.
              </p>
            </div>
            <Layouts.theme_toggle id="settings-theme-toggle" />
          </div>
        </Core.panel>

        <Core.panel id="settings-about" title="About" meta="read-only">
          <dl class="m-0 grid grid-cols-1 sm:grid-cols-[10rem_minmax(0,1fr)] gap-x-4 gap-y-2.5 text-[12.5px]">
            <dt class="text-[var(--text-label)]">Version</dt>
            <dd id="about-version" class="m-0 font-[family-name:var(--font-mono)] break-all">
              v{@version.version} ({@version.sha})
            </dd>

            <%= for {key, label, path} <- @paths do %>
              <dt class="text-[var(--text-label)]">{label}</dt>
              <dd
                id={"about-path-#{key}"}
                class="m-0 font-[family-name:var(--font-mono)] break-all"
              >
                {path}
              </dd>
            <% end %>

            <dt class="text-[var(--text-label)]">Bind address</dt>
            <dd
              id="about-bind-address"
              data-loopback={to_string(@bind.loopback)}
              class="m-0 font-[family-name:var(--font-mono)]"
            >
              {@bind.ip || "default"}
              <span class="text-[var(--text-label)]">
                {if @bind.loopback, do: "(loopback only)", else: "(not loopback)"}
              </span>
            </dd>
          </dl>
          <p class="m-0 mt-4 text-[12px] text-[var(--text-label)]">
            Directories and the bind address are set at deploy time and stay read-only here.
            Provider accounts and credentials live on <.link
              id="settings-providers-link"
              navigate={~p"/providers"}
              class="text-[var(--accent-primary)] hover:underline"
            >
              Providers
            </.link>.
          </p>
        </Core.panel>
      </div>
    </Layouts.app>
    """
  end

  # One row's title, help and effective-value line, shared by every row.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true
  attr :setting, :map, required: true
  attr :effective, :string, required: true
  attr :default, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div
      id={"settings-#{@id}"}
      data-override={to_string(@setting.overridden)}
      class="grid gap-3 py-4 first:pt-0 last:pb-0 sm:grid-cols-[minmax(0,1fr)_minmax(0,22rem)] sm:gap-6"
    >
      <div class="min-w-0">
        <div class="text-[12.5px] font-medium text-[var(--text-title)]">{@label}</div>
        <p class="m-0 mt-0.5 text-[12px] text-[var(--text-label)]">{@help}</p>
        <p class="m-0 mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
          <span>
            in force:
            <span id={"settings-#{@id}-effective"} class="text-[var(--text-primary)]">
              {@effective}
            </span>
          </span>
          <span
            id={"settings-#{@id}-source"}
            class={[
              "px-1.5 py-[1px] rounded-[var(--radius-chip)] border border-solid text-[10px] uppercase tracking-[0.08em]",
              if(@setting.overridden,
                do: "border-[var(--accent-primary)] text-[var(--accent-primary)]",
                else: "border-[var(--border-default)]"
              )
            ]}
          >
            {if @setting.overridden, do: "override", else: "default"}
          </span>
          <span>
            default: <span id={"settings-#{@id}-default"}>{@default}</span>
          </span>
        </p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true
  attr :unit, :string, default: nil
  attr :setting, :map, required: true
  attr :error, :string, default: nil

  defp int_row(assigns) do
    ~H"""
    <.row
      id={@id}
      label={@label}
      help={@help}
      setting={@setting}
      effective={"#{@setting.value}#{@unit && " " <> @unit}"}
      default={"#{@setting.default}#{@unit && " " <> @unit}"}
    >
      <form
        id={"settings-#{@id}-form"}
        phx-submit="save_int"
        class="flex items-start gap-2"
      >
        <input type="hidden" name="setting" value={@id} />
        <div
          id={"settings-#{@id}-field"}
          data-invalid={to_string(not is_nil(@error))}
          class="flex-1 min-w-0"
        >
          <Forms.input
            id={"settings-#{@id}-input"}
            name="value"
            type="text"
            inputmode="numeric"
            autocomplete="off"
            size="sm"
            value={@setting.override}
            placeholder={to_string(@setting.default)}
            error={@error}
          />
        </div>
        <Core.button id={"settings-#{@id}-save"} type="submit" size="sm" variant="primary">
          Save
        </Core.button>
      </form>
    </.row>
    """
  end

  attr :setting, :map, required: true
  attr :error, :string, default: nil
  attr :agent_types, :list, required: true

  defp adapters_row(assigns) do
    assigns = assign(assigns, :mode, adapters_mode(assigns.setting.override))

    ~H"""
    <.row
      id="adapters"
      label="Adapters probed"
      help="Which agent types the watchdog checks. “All” follows whatever adapters are installed; “none” turns probing off."
      setting={@setting}
      effective={adapters_text(@setting.value)}
      default={adapters_text(@setting.default)}
    >
      <form id="settings-adapters-form" phx-submit="save_adapters" class="flex flex-col gap-2.5">
        <div
          id="settings-adapters-field"
          data-invalid={to_string(not is_nil(@error))}
          class="flex flex-col gap-2"
        >
          <label class="flex items-center gap-2 text-[12.5px] cursor-pointer">
            <input
              id="settings-adapters-mode-all"
              type="radio"
              name="mode"
              value="all"
              checked={@mode == "all"}
              class="accent-[var(--accent-primary)]"
            /> All (default)
          </label>
          <label class="flex items-center gap-2 text-[12.5px] cursor-pointer">
            <input
              id="settings-adapters-mode-only"
              type="radio"
              name="mode"
              value="only"
              checked={@mode == "only"}
              class="accent-[var(--accent-primary)]"
            /> Only these
          </label>
          <div class="flex flex-wrap gap-x-4 gap-y-1.5 pl-6">
            <Forms.checkbox
              :for={type <- @agent_types}
              id={"settings-adapter-#{type}"}
              name="adapters[]"
              value={type}
              label={type}
              checked={@mode == "only" and type in @setting.override}
            />
          </div>
          <label class="flex items-center gap-2 text-[12.5px] cursor-pointer">
            <input
              id="settings-adapters-mode-none"
              type="radio"
              name="mode"
              value="none"
              checked={@mode == "none"}
              class="accent-[var(--accent-primary)]"
            /> None
          </label>
          <span :if={@error} class="text-[11.5px] text-[var(--arb-fail-text)]">{@error}</span>
        </div>
        <div>
          <Core.button id="settings-adapters-save" type="submit" size="sm" variant="primary">
            Save
          </Core.button>
        </div>
      </form>
    </.row>
    """
  end

  attr :autopilot, :map, default: nil

  defp autopilot_row(assigns) do
    ~H"""
    <div
      id="settings-autopilot"
      data-state={autopilot_state(@autopilot)}
      class="grid gap-3 py-4 last:pb-0 sm:grid-cols-[minmax(0,1fr)_minmax(0,22rem)] sm:gap-6"
    >
      <div class="min-w-0">
        <div class="text-[12.5px] font-medium text-[var(--text-title)]">Autopilot</div>
        <p class="m-0 mt-0.5 text-[12px] text-[var(--text-label)]">
          While running, the scheduler promotes Ready tickets as slots free up. Pausing only stops the queue draining — work already in flight carries on.
        </p>
        <p
          :if={@autopilot && @autopilot.changed_at}
          id="settings-autopilot-changed"
          class="m-0 mt-2 text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          last changed {format_time(@autopilot.changed_at)}<span :if={@autopilot.changed_by}> by {@autopilot.changed_by}</span>
        </p>
      </div>
      <div class="flex items-center gap-3 sm:justify-end">
        <span
          id="settings-autopilot-state"
          class={[
            "px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em]",
            autopilot_class(@autopilot)
          ]}
        >
          {autopilot_label(@autopilot)}
        </span>
        <Core.button
          :if={@autopilot}
          id="settings-autopilot-toggle"
          type="button"
          size="sm"
          phx-click="toggle_autopilot"
          data-confirm={
            unless @autopilot.paused?,
              do:
                "Pause the scheduler? Ready cards will stop being promoted until it is resumed."
          }
        >
          {if @autopilot.paused?, do: "Resume", else: "Pause"}
        </Core.button>
      </div>
    </div>
    """
  end

  defp autopilot_state(nil), do: "unavailable"
  defp autopilot_state(%{paused?: true}), do: "paused"
  defp autopilot_state(_), do: "running"

  defp autopilot_label(nil), do: "not running"
  defp autopilot_label(%{paused?: true}), do: "paused"
  defp autopilot_label(_), do: "running"

  defp autopilot_class(%{paused?: false}),
    do: "border-[color-mix(in_oklch,var(--arb-live)_45%,transparent)] text-[var(--arb-live)]"

  defp autopilot_class(%{paused?: true}),
    do:
      "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]"

  defp autopilot_class(nil), do: "border-[var(--border-default)] text-[var(--text-label)]"
end
