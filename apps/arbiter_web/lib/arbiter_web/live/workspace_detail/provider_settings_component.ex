defmodule ArbiterWeb.WorkspaceDetail.ProviderSettingsComponent do
  @moduledoc """
  The workspace's provider settings (bd-64apru): which provider accounts each
  role may use, in what preference order, and this workspace's concurrency
  share of each account (`docs/provider-account-design.md` §4.3).

  Everything reads and writes through `Arbiter.Accounts.ProviderSettings`, the
  same model provider routing reads, so what this pane shows as **effective**
  is exactly the candidate set a dispatch selects from — including the
  fallback when a role has no account attached.

  With nothing attached, a role resolves from `agent.type` /
  `review_agent.type`, and the pane shows that hand-written precedence list as
  the role's fallback editor. Once an account is attached, the key is written
  *from* the account list on every change, so the hand editor goes away.

  Like the other list editors on this page, each click is its own write.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  @roles [
    {:implementer, "agent", "Implementer",
     "the worker, its resumes and every fix pass draw on these accounts, first preferred"},
    {:reviewer, "review_agent", "Reviewer",
     "the ReviewGate reviewer draws on these; leave empty to review on the implementer's set"}
  ]

  @role_names %{"implementer" => :implementer, "reviewer" => :reviewer}

  @impl true
  def mount(socket), do: {:ok, assign(socket, :provider_error, nil)}

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  defp load(%{assigns: %{workspace: ws, agent_types: agent_types}} = socket) do
    socket
    |> assign(:roles, Enum.map(@roles, &role_view(ws, &1)))
    |> assign(:attachments, ProviderSettings.attachments(ws))
    |> assign(:accounts, Enum.filter(Accounts.list_accounts(), & &1.enabled))
    |> assign(:account_labels, account_labels(ws, agent_types))
    |> assign(:strategy, strategy(ws))
    |> assign(:ranking, ranking(ws, Map.get(socket.assigns, :routing_opts, [])))
    |> assign(:cross_family?, cfg(ws, ["review_agent", "cross_family"]) == true)
    |> assign(:scoring_mode, scoring_mode(ws))
    |> assign(:scoring_competence?, cfg(ws, ["routing", "scoring", "competence"]) == true)
    |> assign(:pace_exempt, pace_exempt_value(ws))
    |> assign(:pace_exempt_rows, pace_exempt_rows(ws, ProviderSettings.attachments(ws)))
    |> assign(:grok_enabled?, GrokRouting.enabled?(ws))
    |> assign(:grok_difficulties, Enum.join(grok_difficulties(ws), ", "))
    |> assign(:grok_auth, grok_auth(ws))
  end

  # Only the difficulties the workspace spelled out; blank means the default (D1).
  defp grok_difficulties(ws) do
    case cfg(ws, ["routing", "grok", "difficulties"]) do
      [_ | _] = list -> list
      _ -> []
    end
  end

  defp grok_auth(ws) do
    case Arbiter.Grok.AuthReport.report(workspaces: [ws]) do
      %{enabled: true, state: state} -> state
      _ -> nil
    end
  end

  defp strategy(ws),
    do: if(ProviderRouting.enabled?(ws), do: "most_quota", else: "failover")

  # The live most-quota decision a dispatch would make now (no ticket: the
  # workspace's default model tier), or nil while the strategy is failover.
  defp ranking(ws, opts) do
    if ProviderRouting.enabled?(ws) do
      %{available: available, dropped: dropped} = ProviderRouting.availability(ws, nil, opts)

      Enum.map(available, &ranking_row(&1, :available)) ++
        Enum.map(dropped, &ranking_row(&1, :dropped))
    end
  end

  defp ranking_row(entry, :available) do
    %{
      account: entry.account,
      status: "available",
      detail: headroom_text(entry[:headroom])
    }
  end

  defp ranking_row(entry, :dropped),
    do: %{account: entry.account, status: entry.reason, detail: entry[:detail]}

  defp headroom_text(%{headroom: h} = hr) when is_number(h),
    do: "#{Float.round(h * 100, 1)}% headroom#{hr[:window] && " on #{hr.window}"}"

  defp headroom_text(_), do: "no quota reading yet"

  defp role_view(ws, {role, config_key, label, consequence}) do
    resolved = ProviderSettings.effective(ws, role)

    %{
      role: role,
      config_key: config_key,
      label: label,
      consequence: consequence,
      resolved: resolved,
      attached: if(resolved.source == :attached, do: resolved.candidates, else: []),
      adoptable?:
        resolved.source != :attached and Enum.any?(resolved.candidates, &(not is_nil(&1.account)))
    }
  end

  # ---- per-role account lists ----

  @impl true
  def handle_event("add_role_account", %{"role" => role, "account" => id}, socket) do
    write(socket, &ProviderSettings.add(&1, @role_names[role], id))
  end

  def handle_event("remove_role_account", %{"role" => role, "account" => id}, socket) do
    write(socket, &ProviderSettings.remove(&1, @role_names[role], id))
  end

  def handle_event("move_role_account", %{"role" => role, "account" => id, "dir" => dir}, socket)
      when dir in ["up", "down"] do
    write(socket, &ProviderSettings.move(&1, @role_names[role], id, String.to_existing_atom(dir)))
  end

  def handle_event("adopt_role", %{"role" => role}, socket) do
    write(socket, &ProviderSettings.adopt(&1, @role_names[role]))
  end

  def handle_event("set_share", %{"account" => id, "share" => raw}, socket) do
    with {:ok, share} <- parse_share(raw),
         {:ok, _link} <- ProviderSettings.set_share(socket.assigns.workspace, id, share) do
      {:noreply, socket |> assign(:provider_error, nil) |> load()}
    else
      {:error, reason} -> {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  # ---- routing strategy: routing.provider_selection ----

  def handle_event("set_strategy", %{"provider_selection" => value}, socket)
      when value in ["failover", "most_quota"] do
    {patch, unset} =
      case value do
        "failover" -> {%{}, ["routing.provider_selection"]}
        other -> {%{"routing" => %{"provider_selection" => other}}, []}
      end

    case patch_config(socket.assigns.workspace, patch, unset) do
      {:ok, updated} ->
        {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}

      {:error, msg} ->
        {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  # ---- scoring: routing.provider_selection "scored" + routing.scoring.* ----

  def handle_event("set_scoring", params, socket) do
    ws = socket.assigns.workspace

    with {:ok, patch, unset} <- scoring_patch(params, ws),
         {:ok, updated} <- patch_config(ws, patch, unset) do
      {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}
    else
      {:error, msg} -> {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  # ---- workspace pace exemption: quota.pace_exempt_priority ----

  def handle_event("set_pace_exempt", %{"pace_exempt_priority" => raw}, socket) do
    ws = socket.assigns.workspace

    with {:ok, patch, unset} <- pace_exempt_patch(raw),
         {:ok, updated} <- patch_config(ws, patch, unset) do
      {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}
    else
      {:error, msg} -> {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  # ---- grok opt-in: routing.grok.enabled / routing.grok.difficulties ----

  def handle_event("set_grok_routing", params, socket) do
    ws = socket.assigns.workspace

    with {:ok, patch, unset} <- grok_patch(params, ws),
         {:ok, updated} <- patch_config(ws, patch, unset) do
      # The tab bar's grok ring follows this switch; don't make it wait out the cache TTL.
      Arbiter.Quota.QuotaCache.invalidate(ws.id)

      {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}
    else
      {:error, msg} -> {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  # ---- fallback: the agent.type / review_agent.type precedence list ----

  def handle_event("add_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, fn list ->
      if type in list, do: list, else: list ++ [type]
    end)
  end

  def handle_event("remove_agent_type", %{"role" => role, "type" => type}, socket) do
    update_agent_types(socket, role, &List.delete(&1, type))
  end

  def handle_event("move_agent_type", %{"role" => role, "type" => type, "dir" => dir}, socket) do
    update_agent_types(socket, role, &move_type(&1, type, dir))
  end

  # `off` is "not the scored strategy", so it never turns routing off: a
  # workspace that was scored falls back to most_quota, the strategy scoring
  # is built on. The mode key is unset rather than written, so it can't linger
  # and be read back if scored is chosen again.
  defp scoring_patch(%{"scoring_mode" => "off"}, ws) do
    patch =
      if ProviderRouting.scored?(ws),
        do: %{"routing" => %{"provider_selection" => "most_quota"}},
        else: %{}

    {:ok, patch, ["routing.scoring.mode"]}
  end

  defp scoring_patch(%{"scoring_mode" => mode} = params, _ws)
       when mode in ["shadow", "enforce"] do
    scoring = %{"mode" => mode}

    case Map.get(params, "competence") do
      "false" ->
        {:ok, scoring_map(scoring), ["routing.scoring.competence"]}

      "true" ->
        {:ok, scoring_map(Map.put(scoring, "competence", true)), []}

      _ ->
        {:ok, scoring_map(scoring), []}
    end
  end

  defp scoring_patch(_params, _ws), do: {:error, "Scoring must be off, shadow or enforce."}

  defp scoring_map(scoring),
    do: %{"routing" => %{"provider_selection" => "scored", "scoring" => scoring}}

  # Blank hands the decision back to the account (unset), `none` switches the
  # exemption off for this workspace, a priority narrows it.
  defp pace_exempt_patch(""), do: {:ok, %{}, ["quota.pace_exempt_priority"]}
  defp pace_exempt_patch("none"), do: {:ok, %{"quota" => %{"pace_exempt_priority" => "none"}}, []}

  defp pace_exempt_patch(raw) when raw in ~w(0 1 2 3 4),
    do: {:ok, %{"quota" => %{"pace_exempt_priority" => String.to_integer(raw)}}, []}

  defp pace_exempt_patch(_raw),
    do: {:error, "Pace exemption must be blank, none, or a priority from 0 to 4."}

  defp scoring_mode(ws) do
    if ProviderRouting.scored?(ws) do
      if cfg(ws, ["routing", "scoring", "mode"]) == "enforce", do: "enforce", else: "shadow"
    else
      "off"
    end
  end

  defp pace_exempt_value(ws) do
    case cfg(ws, ["quota", "pace_exempt_priority"]) do
      nil -> ""
      value -> to_string(value)
    end
  end

  # What each attached account ends up with: the account grants, this
  # workspace may only narrow — `Quota.Gate.pace_exempt_priority/1`'s own math.
  defp pace_exempt_rows(ws, attachments) do
    for link <- attachments do
      account = link.provider_account

      %{
        account: account,
        granted: account_exempt(account),
        effective: Arbiter.Quota.Gate.pace_exempt_priority({account, ws})
      }
    end
  end

  defp account_exempt(account) do
    Arbiter.Quota.Gate.pace_exempt_priority({account, nil})
  end

  defp exempt_text(nil), do: "off"
  defp exempt_text(0), do: "P0 only"
  defp exempt_text(n), do: "P0 to P#{n}"

  defp grok_patch(%{"enabled" => "true"} = params, ws) do
    raw = Map.get(params, "difficulties", Enum.join(grok_difficulties(ws), ", "))

    case parse_difficulties(raw) do
      {:ok, []} ->
        {:ok, %{"routing" => %{"grok" => %{"enabled" => true}}}, ["routing.grok.difficulties"]}

      {:ok, list} ->
        {:ok, %{"routing" => %{"grok" => %{"enabled" => true, "difficulties" => list}}}, []}

      :error ->
        {:error, "Grok difficulties must be whole numbers from 0 to 5, e.g. \"1, 2\"."}
    end
  end

  defp grok_patch(_params, _ws), do: {:ok, %{}, ["routing.grok.enabled"]}

  defp parse_difficulties(raw) do
    raw
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case Integer.parse(token) do
        {n, ""} when n in 0..5 -> {:cont, {:ok, [n | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, list |> Enum.reverse() |> Enum.uniq()}
      :error -> :error
    end
  end

  defp grok_auth_text(nil), do: "grok routing is off"
  defp grok_auth_text(:logged_in), do: "logged in"
  defp grok_auth_text(:expired), do: "token expired — refreshed on the next dispatch"

  defp grok_auth_text(:reauth_required),
    do: "re-login required: run `grok login --device-code` on the Arbiter host"

  defp grok_auth_text(:not_logged_in),
    do: "not logged in: run `grok login --device-code` on the Arbiter host"

  defp write(socket, fun) do
    case fun.(socket.assigns.workspace) do
      {:ok, %Workspace{} = ws} ->
        {:noreply, socket |> apply_workspace(ws) |> assign(:provider_error, nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, :provider_error, describe(reason))}
    end
  end

  defp update_agent_types(socket, role, fun) do
    ws = socket.assigns.workspace
    new_list = ws |> agent_type_list(role) |> fun.() |> Enum.uniq()
    default = if role == "agent", do: "claude", else: nil

    {patch, unset_paths} =
      case type_value(new_list, default) do
        nil -> {%{}, ["#{role}.type"]}
        value -> {%{role => %{"type" => value}}, []}
      end

    case patch_config(ws, patch, unset_paths) do
      {:ok, updated} ->
        {:noreply, socket |> apply_workspace(updated) |> assign(:provider_error, nil) |> load()}

      {:error, msg} ->
        {:noreply, assign(socket, :provider_error, msg)}
    end
  end

  defp move_type(list, type, "up") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      0 -> list
      idx -> swap(list, idx, idx - 1)
    end
  end

  defp move_type(list, type, "down") do
    case Enum.find_index(list, &(&1 == type)) do
      nil -> list
      idx when idx == length(list) - 1 -> list
      idx -> swap(list, idx, idx + 1)
    end
  end

  defp swap(list, i, j) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  # Collapse a selection back to the config shape: a single provider saves as
  # a scalar string (matching existing single-provider workspaces), several
  # as a pool list. An empty selection falls back to `default` (nil = unset).
  defp type_value([], default), do: default
  defp type_value([single], _default), do: single
  defp type_value(many, _default) when is_list(many), do: many

  defp agent_type_list(ws, role) do
    case cfg(ws, [role, "type"]) do
      t when is_binary(t) -> [t]
      types when is_list(types) -> types
      _ -> []
    end
  end

  # P10 (`docs/provider-account-design.md` §8, bd-icwk2k): which account a
  # fallback type is metered under, `%{"claude" => "personal-max"}`. A plain
  # read of the link, like `Usage`/`Quota`'s own account reads.
  defp account_labels(%Workspace{id: ws_id}, agent_types) do
    for provider <- agent_types,
        account = Arbiter.Accounts.Resolver.account(ws_id, provider),
        not is_nil(account),
        into: %{} do
      {provider, account.slug}
    end
  end

  defp parse_share(raw) do
    case blank_to_nil(raw) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, :invalid_share}
        end
    end
  end

  defp describe({:provider_taken, account}),
    do:
      "This workspace already uses #{ref(account)} for #{account.provider}, in another role — " <>
        "one account per provider per workspace. Remove it there first."

  defp describe(:disabled), do: "That account is disabled; enable it on the Providers page first."

  defp describe({:merged_away, _}),
    do: "That account was merged into another; attach the surviving account instead."

  defp describe(:nothing_to_adopt),
    do: "None of the configured types is linked to an account yet."

  defp describe(:invalid_share), do: "Share must be a whole number of slots, 0 or more."
  defp describe(:not_attached), do: "That account is not attached to this workspace."
  defp describe(:not_found), do: "No such account."
  defp describe(%{__exception__: true} = err), do: error_message(err)
  defp describe(other), do: inspect(other)

  defp ref(account), do: "#{account.provider}:#{account.slug}"

  # ---- render ----

  @source_labels %{
    attached: "attached accounts",
    agent_type: "fallback · agent.type",
    review_agent_type: "fallback · review_agent.type",
    implementer: "fallback · implementer's set",
    default: "fallback · default"
  }

  defp source_label(source), do: Map.fetch!(@source_labels, source)

  defp addable(accounts, attached) do
    ids = MapSet.new(attached, & &1.account.id)
    Enum.reject(accounts, &MapSet.member?(ids, &1.id))
  end

  defp strategy_options,
    do: [
      {"failover",
       "the order above decides: the first healthy provider wins. A quota-held provider still counts as healthy."},
      {"most_quota",
       "the attached implementer account with the most headroom against its pace wins; the order only breaks ties."}
    ]

  defp scoring_options,
    do: [
      {"off", "no scoring: the strategy above decides."},
      {"shadow",
       "dispatch by most_quota and record what the scorer would have picked, to compare before trusting it."},
      {"enforce", "dispatch by the scorer's order."}
    ]

  defp pace_exempt_options,
    do: [
      {"Inherit the account's grant", ""},
      {"None — switch it off here", "none"},
      {"P0 only", "0"},
      {"P0 to P1", "1"},
      {"P0 to P2", "2"},
      {"P0 to P3", "3"},
      {"P0 to P4", "4"}
    ]

  defp cap_text(nil), do: "∞"
  defp cap_text(n), do: Integer.to_string(n)

  defp roles_of(link) do
    [
      link.implementer_position && "implementer",
      link.reviewer_position && "reviewer"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "metering only"
      roles -> Enum.join(roles, " · ")
    end
  end

  attr :resolved, :map, required: true

  defp effective_line(assigns) do
    ~H"""
    <div
      id={"provider-effective-#{@resolved.role}"}
      data-source={@resolved.source}
      class="flex flex-wrap items-center gap-1.5 rounded-[var(--radius-field)] bg-[var(--arb-raised)] px-2 py-1.5"
    >
      <span class="font-[family-name:var(--font-mono)] text-[10px] uppercase tracking-[0.06em] text-[var(--text-label)]">
        effective
      </span>
      <span class={[
        "rounded-[var(--radius-chip)] px-[6px] py-[1px] font-[family-name:var(--font-mono)] text-[10px]",
        if(@resolved.source == :attached,
          do: "bg-[var(--arb-live-wash)] text-[var(--arb-live)]",
          else: "bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]"
        )
      ]}>
        {source_label(@resolved.source)}
      </span>
      <span
        :for={{c, idx} <- Enum.with_index(@resolved.candidates)}
        data-candidate={c.agent_type}
        class={[value_chip(), "gap-1"]}
      >
        <span class="text-[var(--text-label)]">{idx + 1}</span>
        <.provider_icon provider={c.agent_type} class="size-3" />
        <%= if c.account do %>
          {c.account.slug}
          <span class="text-[var(--text-label)]">cap {cap_text(c.cap)}</span>
        <% else %>
          {c.agent_type} <span class="text-[var(--text-label)]">· no linked account</span>
        <% end %>
      </span>
    </div>
    """
  end

  attr :role, :map, required: true
  attr :accounts, :list, required: true
  attr :target, :any, required: true

  defp role_accounts(assigns) do
    assigns = assign(assigns, :addable, addable(assigns.accounts, assigns.role.attached))

    ~H"""
    <ol id={"provider-role-#{@role.role}"} class="m-0 flex flex-col gap-1 p-0">
      <li
        :for={{c, idx} <- Enum.with_index(@role.attached)}
        id={"provider-role-#{@role.role}-#{c.account.id}"}
        class="flex items-center gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-2 py-1 font-[family-name:var(--font-mono)] text-[11.5px] transition-colors duration-150 hover:border-[var(--border-strong)]"
      >
        <span class="w-4 text-[var(--text-label)]">{idx + 1}</span>
        <.provider_icon provider={c.agent_type} class="size-3.5" />
        <span class="flex-1 truncate text-[var(--arb-text-body)]">
          {c.account.label || c.account.slug}
          <span class="text-[var(--text-label)]">{c.provider}:{c.account.slug}</span>
        </span>
        <span class="text-[10px] text-[var(--text-label)]" title="min(account ceiling, share)">
          cap {cap_text(c.cap)}
        </span>
        <button
          type="button"
          phx-target={@target}
          phx-click="move_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          phx-value-dir="up"
          disabled={idx == 0}
          class={icon_button()}
          aria-label={"Prefer #{c.account.slug}"}
        >
          <Core.icon name="hero-chevron-up" size={12} />
        </button>
        <button
          type="button"
          phx-target={@target}
          phx-click="move_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          phx-value-dir="down"
          disabled={idx == length(@role.attached) - 1}
          class={icon_button()}
          aria-label={"Demote #{c.account.slug}"}
        >
          <Core.icon name="hero-chevron-down" size={12} />
        </button>
        <button
          type="button"
          phx-target={@target}
          phx-click="remove_role_account"
          phx-value-role={@role.role}
          phx-value-account={c.account.id}
          class={icon_button(:danger)}
          aria-label={"Remove #{c.account.slug} from #{@role.label}"}
        >
          <Core.icon name="hero-x-mark" size={12} />
        </button>
      </li>
      <li
        :if={@role.attached == []}
        class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
      >
        No accounts attached — resolving from config below.
      </li>
    </ol>
    <div :if={@addable != [] or @role.adoptable?} class="mt-1 flex flex-wrap gap-1">
      <button
        :if={@role.adoptable?}
        id={"adopt-#{@role.role}"}
        type="button"
        phx-target={@target}
        phx-click="adopt_role"
        phx-value-role={@role.role}
        class={[
          value_chip(),
          "cursor-pointer gap-1 border-[var(--accent-primary)] text-[var(--accent-primary)] hover:bg-[var(--arb-raised)]"
        ]}
        title="Attach the accounts the config fallback already resolves to, in the same order"
      >
        <Core.icon name="hero-arrow-down-on-square" size={11} /> adopt current setting
      </button>
      <button
        :for={account <- @addable}
        type="button"
        phx-target={@target}
        phx-click="add_role_account"
        phx-value-role={@role.role}
        phx-value-account={account.id}
        class={[
          value_chip(),
          "cursor-pointer gap-1 transition-colors duration-150 hover:border-[var(--accent-primary)] hover:text-[var(--text-body)]"
        ]}
      >
        <Core.icon name="hero-plus" size={11} />
        <.provider_icon provider={ProviderSettings.agent_type(account.provider)} class="size-3" />
        {account.provider}:{account.slug}
      </button>
    </div>
    """
  end

  attr :role, :string, required: true
  attr :label, :string, required: true
  attr :consequence, :string, required: true
  attr :selected, :list, required: true
  attr :available, :list, required: true
  attr :target, :any, required: true
  attr :account_labels, :map, default: %{}

  defp agent_type_editor(assigns) do
    ~H"""
    <.setting_row name={@label} consequence={@consequence}>
      <:below>
        <ol class="m-0 flex flex-col gap-1 p-0">
          <li
            :for={{type, idx} <- Enum.with_index(@selected)}
            class="flex items-center gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-2 py-1 font-[family-name:var(--font-mono)] text-[11.5px]"
          >
            <span class="w-4 text-[var(--text-label)]">{idx + 1}</span>
            <span class="flex-1 text-[var(--arb-text-body)]">{type}</span>
            <span
              :if={Map.get(@account_labels, type)}
              class="text-[9.5px] text-[var(--text-label)]"
              title={"Provider account this workspace's #{type} is metered under"}
            >
              account: {Map.get(@account_labels, type)}
            </span>
            <button
              type="button"
              phx-target={@target}
              phx-click="move_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              phx-value-dir="up"
              disabled={idx == 0}
              class={icon_button()}
              aria-label={"Move #{type} up"}
            >
              <Core.icon name="hero-chevron-up" size={12} />
            </button>
            <button
              type="button"
              phx-target={@target}
              phx-click="move_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              phx-value-dir="down"
              disabled={idx == length(@selected) - 1}
              class={icon_button()}
              aria-label={"Move #{type} down"}
            >
              <Core.icon name="hero-chevron-down" size={12} />
            </button>
            <button
              type="button"
              phx-target={@target}
              phx-click="remove_agent_type"
              phx-value-role={@role}
              phx-value-type={type}
              class={icon_button(:danger)}
              aria-label={"Remove #{type}"}
            >
              <Core.icon name="hero-x-mark" size={12} />
            </button>
          </li>
          <li
            :if={@selected == []}
            class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
          >
            None selected.
          </li>
        </ol>
        <div :if={@available != []} class="mt-1 flex flex-wrap gap-1">
          <button
            :for={type <- @available}
            type="button"
            phx-target={@target}
            phx-click="add_agent_type"
            phx-value-role={@role}
            phx-value-type={type}
            class={[
              value_chip(),
              "cursor-pointer gap-1 hover:border-[var(--accent-primary)] hover:text-[var(--text-body)]"
            ]}
          >
            <Core.icon name="hero-plus" size={11} /> {type}
          </button>
        </div>
      </:below>
    </.setting_row>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="provider-settings" class={pane_class("providers", @section)}>
      <p
        id="provider-settings-help"
        class="m-0 mb-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
      >
        This pane decides which providers get this workspace's work. Attaching an account on the
        <.link navigate={~p"/providers"} class="underline">Providers page</.link>
        only adds metering and concurrency.
      </p>
      <.rows>
        <%= for role <- @roles do %>
          <.setting_row
            name={"#{role.label} accounts"}
            consequence={"#{role.config_key}.type is written from this list — #{role.consequence}"}
          >
            <:below>
              <div class="flex flex-col gap-2">
                <.effective_line resolved={role.resolved} />
                <.role_accounts role={role} accounts={@accounts} target={@myself} />
              </div>
            </:below>
          </.setting_row>

          <.agent_type_editor
            :if={role.attached == []}
            role={role.config_key}
            target={@myself}
            label={"#{role.label} fallback"}
            consequence={
              if role.role == :implementer,
                do:
                  "agent.type — used while no account is attached; dispatch takes the first type that is installed and under quota",
                else:
                  "review_agent.type — used while no account is attached; leave empty and reviews run on the implementer's set"
            }
            selected={agent_type_list(@workspace, role.config_key)}
            available={@agent_types -- agent_type_list(@workspace, role.config_key)}
            account_labels={@account_labels}
          />
        <% end %>

        <.setting_row
          name="Implementer routing"
          consequence="routing.provider_selection — how a dispatch picks among the implementer accounts above"
        >
          <:below>
            <div class="flex flex-col gap-2">
              <.form
                for={%{}}
                id="routing-strategy-form"
                phx-change="set_strategy"
                phx-target={@myself}
                class="flex flex-col gap-1"
              >
                <label
                  :for={{value, text} <- strategy_options()}
                  class="flex items-start gap-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--arb-text-body)]"
                >
                  <input
                    type="radio"
                    name="provider_selection"
                    value={value}
                    checked={@strategy == value}
                    class="mt-[2px]"
                  />
                  <span>
                    <span class="font-semibold">{value}</span>
                    <span id={"routing-help-#{value}"} class="text-[var(--text-label)]">
                      — {text}
                    </span>
                  </span>
                </label>
              </.form>
              <ul
                :if={@ranking}
                id="routing-ranking"
                class="m-0 flex flex-col gap-1 p-0 font-[family-name:var(--font-mono)] text-[11px]"
              >
                <li class="text-[10px] uppercase tracking-[0.06em] text-[var(--text-label)]">
                  next ticket goes to the first available, best headroom first
                </li>
                <li
                  :for={{row, idx} <- Enum.with_index(@ranking)}
                  data-account={row.account.id}
                  data-status={row.status}
                  class="flex items-center gap-2 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-2 py-1"
                >
                  <span class="w-4 text-[var(--text-label)]">{idx + 1}</span>
                  <span class="flex-1 truncate">{row.account.provider}:{row.account.slug}</span>
                  <span class={[
                    "rounded-[var(--radius-chip)] px-[6px] py-[1px] text-[10px]",
                    if(row.status == "available",
                      do: "bg-[var(--arb-live-wash)] text-[var(--arb-live)]",
                      else: "bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]"
                    )
                  ]}>
                    {row.status}
                  </span>
                  <span class="text-[var(--text-label)]">{row.detail}</span>
                </li>
                <li :if={@ranking == []} class="text-[var(--text-label)]">
                  No implementer accounts attached — dispatch falls back to agent.type.
                </li>
              </ul>
              <p
                id="routing-reviewer-note"
                class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
              >
                <%= if @cross_family? do %>
                  Reviewer: cross-family routing — candidates outside the implementer's model family, held or expired ones dropped, ranked by quota headroom (order breaks ties); falls back to the implementer's family only when no other family is available.
                <% else %>
                  Reviewer: first healthy entry in its own order (review_agent.type / reviewer accounts); routing.provider_selection does not apply.
                <% end %>
              </p>
            </div>
          </:below>
        </.setting_row>

        <.setting_row
          name="Scoring"
          consequence="routing.provider_selection: scored + routing.scoring.mode — price each implementer account by headroom ÷ expected draw instead of headroom alone. Shadow dispatches like most_quota and only records the scorer's pick; enforce dispatches by it"
        >
          <:below>
            <.form
              for={%{}}
              id="scoring-form"
              phx-change="set_scoring"
              phx-target={@myself}
              class="flex flex-col gap-1"
            >
              <label
                :for={{value, text} <- scoring_options()}
                class="flex items-start gap-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--arb-text-body)]"
              >
                <input
                  type="radio"
                  name="scoring_mode"
                  value={value}
                  checked={@scoring_mode == value}
                  class="mt-[2px]"
                />
                <span>
                  <span class="font-semibold">{value}</span>
                  <span id={"scoring-help-#{value}"} class="text-[var(--text-label)]">
                    — {text}
                  </span>
                </span>
              </label>
              <label
                :if={@scoring_mode != "off"}
                id="scoring-competence"
                class="mt-1 flex items-start gap-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--arb-text-body)]"
              >
                <input type="hidden" name="competence" value="false" />
                <input
                  type="checkbox"
                  name="competence"
                  value="true"
                  checked={@scoring_competence?}
                  class="mt-[2px]"
                />
                <span>
                  <span class="font-semibold">Use the competence matrix</span>
                  <span class="text-[var(--text-label)]">
                    — estimate each model's draw and time to close by task difficulty (routing.scoring.competence)
                  </span>
                </span>
              </label>
            </.form>
          </:below>
        </.setting_row>

        <.setting_row
          name="Pace exemption"
          consequence="quota.pace_exempt_priority — narrows which tickets may run past an account's paced line. The account grants the exemption; this workspace can only narrow it, never grant it"
        >
          <:below>
            <div class="flex flex-col gap-2">
              <.form
                for={%{}}
                id="pace-exempt-form"
                phx-change="set_pace_exempt"
                phx-target={@myself}
                class="flex items-center gap-2 font-[family-name:var(--font-mono)] text-[11px]"
              >
                <Forms.select
                  id="pace-exempt-priority"
                  name="pace_exempt_priority"
                  value={@pace_exempt}
                  size="sm"
                  aria-label="Pace exemption for this workspace"
                  options={pace_exempt_options()}
                />
              </.form>
              <ul
                :if={@pace_exempt_rows != []}
                id="pace-exempt-effective"
                class="m-0 flex flex-col gap-1 p-0 list-none font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
              >
                <li :for={row <- @pace_exempt_rows} id={"pace-exempt-effective-#{row.account.id}"}>
                  {row.account.provider}:{row.account.slug} grants {exempt_text(row.granted)} →
                  <span class="text-[var(--arb-text-body)]">
                    effective {exempt_text(row.effective)}
                  </span>
                </li>
              </ul>
              <p class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]">
                An account that grants nothing exempts nothing, whatever is set here. Change what an account grants on the <.link
                  navigate={~p"/providers"}
                  class="underline"
                >Providers page</.link>.
              </p>
            </div>
          </:below>
        </.setting_row>

        <.setting_row
          name="Route D1 tickets to Grok"
          consequence="routing.grok.enabled — grok is free-tier and never takes agent.type; this opt-in is the only way work reaches it"
        >
          <:below>
            <.form
              for={%{}}
              id="grok-routing-form"
              phx-change="set_grok_routing"
              phx-target={@myself}
              class="flex flex-col gap-2 font-[family-name:var(--font-mono)] text-[11px] text-[var(--arb-text-body)]"
            >
              <label class="flex items-center gap-2">
                <input type="hidden" name="enabled" value="false" />
                <input type="checkbox" name="enabled" value="true" checked={@grok_enabled?} />
                <span class="font-semibold">Route D1 tickets to Grok</span>
              </label>
              <label :if={@grok_enabled?} id="grok-difficulties" class="flex items-center gap-2">
                <span class="text-[var(--text-label)]">difficulties</span>
                <input
                  type="text"
                  name="difficulties"
                  value={@grok_difficulties}
                  placeholder="1"
                  phx-debounce="blur"
                  aria-label="Grok difficulties"
                  class="w-[96px]"
                />
                <span class="text-[var(--text-label)]">blank = D1 only; 0–5, comma separated</span>
              </label>
              <span
                id="grok-auth-state"
                data-state={@grok_auth || "off"}
                class="text-[var(--text-label)]"
              >
                Grok auth: {grok_auth_text(@grok_auth)}
              </span>
            </.form>
          </:below>
        </.setting_row>

        <.setting_row
          name="Concurrency share"
          consequence="per account, this workspace's cap on the account's ceiling (§4.3) — a cap, not a reservation; blank = no workspace cap"
        >
          <:below>
            <ul :if={@attachments != []} id="provider-shares" class={list_class()}>
              <.list_row :for={link <- @attachments} id={"share-row-#{link.provider_account_id}"}>
                <.provider_icon
                  provider={ProviderSettings.agent_type(link.provider)}
                  class="size-3.5"
                />
                <span class="flex-1 truncate">
                  {link.provider}:{link.provider_account.slug}
                  <span class="text-[10px] text-[var(--text-label)]">{roles_of(link)}</span>
                </span>
                <span class="text-[10px] text-[var(--text-label)]">
                  ceiling {cap_text(link.provider_account.max_concurrent)}
                </span>
                <.form
                  for={%{}}
                  id={"share-form-#{link.provider_account_id}"}
                  phx-submit="set_share"
                  phx-target={@myself}
                  class="flex items-center gap-1"
                >
                  <input type="hidden" name="account" value={link.provider_account_id} />
                  <Forms.input
                    name="share"
                    value={link.share}
                    size="sm"
                    inputmode="numeric"
                    placeholder="none"
                    class="w-[64px]"
                    aria-label={"Share of #{link.provider_account.slug}"}
                  />
                  <Core.button type="submit" size="sm">Set</Core.button>
                </.form>
                <span
                  id={"share-cap-#{link.provider_account_id}"}
                  class="w-[52px] text-right text-[10.5px] text-[var(--text-secondary)]"
                  title="effective cap = min(account ceiling, share)"
                >
                  cap {cap_text(
                    ProviderSettings.cap(link.provider_account.max_concurrent, link.share)
                  )}
                </span>
              </.list_row>
            </ul>
            <p
              :if={@attachments == []}
              class="m-0 font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
            >
              No accounts linked to this workspace yet.
            </p>
          </:below>
        </.setting_row>
      </.rows>

      <p
        :if={@provider_error}
        id="provider-settings-error"
        class="m-0 text-[11px] text-[var(--arb-fail-text)]"
      >
        {@provider_error}
      </p>
    </div>
    """
  end
end
