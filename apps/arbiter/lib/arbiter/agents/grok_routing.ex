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

  `Arbiter.Agents.Routing.ByDifficulty` consults `route?/2` after it has
  merged its rule; a workspace that never sets `routing.grok.enabled` sees no
  change. A workspace can still pin `agent.type: "grok"` outright, which is
  the explicit override.
  """

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

  @doc "Whether a task of `difficulty` (already clamped, 0..5) goes to grok."
  @spec route?(Workspace.t() | nil, 0..5) :: boolean()
  def route?(workspace, difficulty),
    do: enabled?(workspace) and difficulty in difficulties(workspace)

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
