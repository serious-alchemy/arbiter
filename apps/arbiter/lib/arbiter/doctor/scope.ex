defmodule Arbiter.Doctor.Scope do
  @moduledoc """
  What this install uses, for `arb server doctor`'s applicability (bd-7pnat1,
  `GET /api/server/doctor_scope`).

  The doctor reports a check only when it can matter here: grok's login when a
  workspace routes to grok, the agy jail when agy is configured and not paused,
  podman readiness when a workspace's sandbox or review backend is podman, the
  egress jail when a workspace enforces an egress allowlist. The CLI cannot
  derive those from `GET /api/workspaces` alone (an attached account, a repo
  override and a provider pause all count), so the server answers them from the
  same readers the dispatch path uses:

    * `providers` — per adapter type (`claude`, `codex`, `gemini` = agy,
      `grok`): `in_use` (some workspace's implementer or reviewer set, per
      `Arbiter.Accounts.ProviderSettings.effective/2`, names it; grok also when
      `Arbiter.Agents.GrokRouting.in_use?/1`), the workspaces that use it, and
      `paused` (`Arbiter.Providers.Pause.provider_paused?/1`).
    * `podman_in_use` — a workspace, or a repo override, resolves
      `sandbox.backend` or `sandbox.review_backend` to podman.
    * `egress_enforced` — a workspace or repo override resolves a non-`open`
      egress.
  """

  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.Workspace

  @providers ~w(claude codex gemini grok)

  @doc "The scope report. Option `:workspaces` overrides the read (tests)."
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    workspaces = Keyword.get_lazy(opts, :workspaces, fn -> Ash.read!(Workspace) end)
    policies = Enum.flat_map(workspaces, &policies/1)

    %{
      providers: Map.new(@providers, &{&1, provider(&1, workspaces)}),
      podman_in_use: Enum.any?(policies, &podman?/1),
      egress_enforced: Enum.any?(policies, &(SecurityPolicy.egress(&1) != :open))
    }
  end

  defp provider(type, workspaces) do
    using = for ws <- workspaces, uses?(ws, type), do: ws.name

    %{in_use: using != [], workspaces: using, paused: Pause.provider_paused?(type)}
  end

  defp uses?(ws, type) do
    candidate_types(ws) |> Enum.member?(type) or (type == "grok" and GrokRouting.in_use?(ws))
  end

  defp candidate_types(ws) do
    for role <- ProviderSettings.roles(),
        c <- ProviderSettings.effective(ws, role).candidates,
        do: c.agent_type
  end

  # The workspace's own resolved policy plus one per `agent.security.repos`
  # override: a repo can pick podman or an allowlist while the workspace
  # default does not.
  defp policies(ws) do
    repos =
      case get_in(ws.config || %{}, ["agent", "security", "repos"]) do
        repos when is_map(repos) -> Map.keys(repos)
        _ -> []
      end

    [SecurityPolicy.resolve(ws) | Enum.map(repos, &SecurityPolicy.resolve(ws, %{}, &1))]
  end

  defp podman?(policy) do
    :podman in [SecurityPolicy.sandbox_backend(policy), SecurityPolicy.review_backend(policy)]
  end
end
