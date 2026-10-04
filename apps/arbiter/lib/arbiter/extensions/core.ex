defmodule Arbiter.Extensions.Core do
  @moduledoc """
  Arbiter's own adapters, registered the way an external package would.

  `Arbiter.Extensions` loads this first and applies exactly the same checks to
  it as to anything named in `config :arbiter, :extensions`. Because it is
  first, its keys are the ones an external extension cannot shadow.
  """

  @behaviour Arbiter.Extension

  alias Arbiter.Agents.Routing
  alias Arbiter.Mergers

  @impl true
  def contributions do
    [
      {:agent, "claude", Arbiter.Agents.Claude},
      {:agent, "gemini", Arbiter.Agents.Gemini},
      {:agent, "codex", Arbiter.Agents.Codex},
      {:tracker, "none", Arbiter.Trackers.None},
      {:tracker, "jira", Arbiter.Trackers.Jira},
      {:tracker, "shortcut", Arbiter.Trackers.Shortcut},
      {:tracker, "linear", Arbiter.Trackers.Linear},
      {:tracker, "github", Arbiter.Trackers.GitHub},
      {:tracker, "gitlab", Arbiter.Trackers.Gitlab},
      {:merger, "direct", Mergers.Direct},
      {:merger, "gitlab", Mergers.Gitlab},
      {:merger, "github", Mergers.Github},
      {:routing_policy, "static", Routing.Static},
      {:routing_policy, "by_priority", Routing.ByPriority},
      {:routing_policy, "by_difficulty", Routing.ByDifficulty},
      {:routing_policy, "by_budget", Routing.ByBudget},
      {:routing_policy, "round_robin", Routing.RoundRobin},
      {:quota_gate, "throttle", Arbiter.Quota.Gate.Throttle},
      {:quota_gate, "continue", Arbiter.Quota.Gate.Continue},
      {:session_provider, "claude_code", Arbiter.Sessions.Provider.ClaudeCode},
      {:session_provider, "agy", Arbiter.Sessions.Provider.Agy},
      {:mcp_agent_config, "claude", Arbiter.MCP.AgentConfig.Claude},
      {:mcp_agent_config, "gemini", Arbiter.MCP.AgentConfig.Gemini},
      {:mcp_agent_config, "codex", Arbiter.MCP.AgentConfig.Codex}
    ]
  end
end
