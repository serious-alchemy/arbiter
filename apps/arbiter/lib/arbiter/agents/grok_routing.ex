defmodule Arbiter.Agents.GrokRouting do
  @moduledoc """
  Per-workspace opt-in for routing work to grok (bd-dpv4vt, epic bd-6f3edy).

  grok runs on the free tier only (about 500K tokens per rolling 24 h, cached
  tokens counted), so one small task costs roughly an eighth of a day. It is
  therefore **off** for every workspace and, once on, takes only the cheapest
  work:

      routing:
        grok:
          enabled: true          # default false
          difficulties: [1]      # default [1] — D1 tickets only

  `Arbiter.Agents.Routing.choose/3` consults `route?/2` after the policy has
  chosen, so it holds under every routing policy, and `Dispatch.maybe_route/3`
  keeps quota/scored provider routing from overriding it. A workspace that never sets `routing.grok.enabled` sees no
  change. A workspace can still pin `agent.type: "grok"` outright, which is
  the explicit override.

  ## An open auth hold stops routing (bd-8rvkqd)

  While grok's `Arbiter.Agents.AuthHold` (or a `CredentialWatchdog` expiry) is
  open, `route?/3` is `false`: grok is not selected, so the policy's own choice
  stands and a ticket reopened by `Arbiter.Worker.AuthDeath` goes to the next
  eligible provider instead of back into the dead login. The routing comes
  back by itself when the hold clears.
  """

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Tasks.Workspace

  @default_difficulties [1]

  @doc "Whether the workspace has switched grok routing on."
  @spec enabled?(Workspace.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "grok", "enabled"]) == true

  def enabled?(_), do: false

  @doc "The difficulties (0..5) routed to grok when enabled; D1 unless overridden."
  @spec difficulties(Workspace.t() | nil) :: [0..5]
  def difficulties(%Workspace{config: config}) do
    case get_in(config || %{}, ["routing", "grok", "difficulties"]) do
      [_ | _] = list ->
        case Enum.filter(list, &(is_integer(&1) and &1 in 0..5)) do
          [] -> @default_difficulties
          valid -> valid
        end

      _ ->
        @default_difficulties
    end
  end

  def difficulties(_), do: @default_difficulties

  @doc """
  Moves `choice` to grok when `route?/2` holds. The pinned `"model"` is
  dropped — it belongs to the provider the policy picked, not to grok.
  """
  @spec apply_choice(map(), Workspace.t() | nil, 0..5, keyword()) :: map()
  def apply_choice(choice, workspace, difficulty, opts \\ []) do
    if route?(workspace, difficulty, opts),
      do: %{choice | type: :grok, config: Map.drop(choice.config, ["model"])},
      else: choice
  end

  @doc """
  Whether a task of `difficulty` (already clamped, 0..5) goes to grok: opted in,
  a routed difficulty, no open grok auth hold, grok not paused (provider- or
  account-wide, bd-bvx07f) and, when `:task` is given, grok allowed by the
  ticket's provider constraint. Grok is a routing candidate like any other: a
  pause or a constraint that rules it out sends the ticket to the policy's own
  choice. Options: `:task`; (tests) `:auth_hold` and `:credential_watchdog`.
  """
  @spec route?(Workspace.t() | nil, 0..5, keyword()) :: boolean()
  def route?(workspace, difficulty, opts \\ []) do
    enabled?(workspace) and difficulty in difficulties(workspace) and not held?(opts) and
      not paused?(workspace) and allowed?(Keyword.get(opts, :task))
  end

  defp paused?(workspace) do
    ws_id = if match?(%Workspace{}, workspace), do: workspace.id
    Arbiter.Providers.Pause.blocking(:grok, ws_id) != nil
  rescue
    _ -> false
  end

  defp allowed?(nil), do: true
  defp allowed?(task), do: Arbiter.Agents.ProviderConstraint.allows?(task, :grok)

  @doc """
  Whether grok dispatch is held on its credential: an open `AuthHold`
  (fail-closed when unreadable) or a `CredentialWatchdog` expiry.
  """
  @spec held?(keyword()) :: boolean()
  def held?(opts \\ []) do
    adapter = Arbiter.Agents.Grok

    AuthHold.open?(adapter, Keyword.get(opts, :auth_hold, AuthHold)) or
      CredentialWatchdog.expired?(
        adapter,
        Keyword.get(opts, :credential_watchdog, CredentialWatchdog)
      )
  end

  @doc """
  Whether grok can run in `workspace` at all: routed to (`enabled?/1`) or
  pinned as its `agent.type` (a string or a list of strings).
  """
  @spec in_use?(Workspace.t() | nil) :: boolean()
  def in_use?(%Workspace{config: config} = ws) do
    enabled?(ws) or
      case get_in(config || %{}, ["agent", "type"]) do
        "grok" -> true
        list when is_list(list) -> "grok" in list
        _ -> false
      end
  end

  def in_use?(_), do: false
end
