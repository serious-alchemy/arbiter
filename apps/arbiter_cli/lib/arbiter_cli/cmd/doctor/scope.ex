defmodule ArbiterCli.Cmd.Doctor.Scope do
  @moduledoc """
  What this install uses, for `arb server doctor`'s applicability (bd-7pnat1).

  Read once per doctor run from `GET /api/server/doctor_scope`
  (`Arbiter.Doctor.Scope`). A check declares when it applies (`:always`,
  `{:provider, type}`, `:podman`, `:egress`); `applies?/2` answers `:yes` or
  `{:no, reason}`. A scope the server cannot give — an older server, an error —
  is `known?: false` and every check applies: hiding a check because the scope
  could not be read would be the same "ok on unknown" the severity model exists
  to stop.
  """

  alias ArbiterCli.Client

  defstruct known?: false, providers: %{}, podman_in_use: true, egress_enforced: true

  @type t :: %__MODULE__{}

  @type applies_when :: :always | {:provider, String.t()} | :podman | :egress

  @labels %{"gemini" => "agy", "claude" => "claude", "codex" => "codex", "grok" => "grok"}

  @spec fetch() :: t()
  def fetch do
    case Client.get("/api/server/doctor_scope") do
      {:ok, %{"providers" => providers} = body} when is_map(providers) ->
        %__MODULE__{
          known?: true,
          providers: providers,
          podman_in_use: body["podman_in_use"] == true,
          egress_enforced: body["egress_enforced"] == true
        }

      _ ->
        %__MODULE__{}
    end
  end

  @spec applies?(t(), applies_when()) :: :yes | {:no, String.t()}
  def applies?(%__MODULE__{known?: false}, _when), do: :yes
  def applies?(%__MODULE__{}, :always), do: :yes

  def applies?(%__MODULE__{podman_in_use: false}, :podman),
    do: {:no, "no workspace uses the podman sandbox backend"}

  def applies?(%__MODULE__{egress_enforced: false}, :egress),
    do: {:no, "no workspace enforces an egress allowlist (`agent.security.sandbox.egress: allowlist | none`)"}

  def applies?(%__MODULE__{providers: providers}, {:provider, type}) do
    label = Map.get(@labels, type, type)

    case Map.get(providers, type) do
      %{"in_use" => false} ->
        {:no, "#{label} is not configured for any workspace"}

      %{"paused" => true} ->
        {:no, "#{label} is paused (`arb provider resume`), so no spawn uses it"}

      _ ->
        :yes
    end
  end

  def applies?(%__MODULE__{}, _when), do: :yes
end
