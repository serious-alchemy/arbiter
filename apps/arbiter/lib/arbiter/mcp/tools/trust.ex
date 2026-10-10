defmodule Arbiter.MCP.Tools.Trust do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for earned trust (G18,
  `docs/design/guardrail-profiles.md` §6.3–6.5): `trust_show`, `trust_confirm`
  and `trust_dismiss`, the twins of `arb trust show` / `confirm` / `dismiss`.
  Coordinator-only, like `GET /api/trust` and its decision routes.

  There is deliberately no `trust_promote`. A promotion loosens a subject's
  guardrails, so it needs operator proof (`arb trust promote` from the
  operator's own shell); no MCP tool, at any tier, can promote, and
  `loop_pending_apply` refuses a `trust_promotion` proposal outright
  (`Arbiter.Loop.inapplicable_reason/1`).
  """

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Loop.Trust
  alias Arbiter.Loop.Trust.View
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools

  @doc """
  Every subject's tier and record, or — with `subject` (`provider/model`) — that
  one subject in full: recent events, history and any pending promotion
  proposal. Coordinator only.
  """
  @spec trust_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def trust_show(%Scope{}, args) do
    case Tools.fetch_string(args, "subject") do
      nil ->
        subjects = View.list()
        {:ok, %{subjects: subjects, count: length(subjects)}}

      subject ->
        with {:ok, _} <- parse(subject) do
          case View.detail(subject) do
            {:ok, detail} -> {:ok, %{subject: detail}}
            {:error, :not_found} -> {:error, {:not_found, "no trust record for #{subject}"}}
          end
        end
    end
  end

  @doc """
  Confirm an automatic suspension of `subject`: the demotion to `quarantine`
  stands (`Arbiter.Loop.Trust.confirm/2`). Coordinator only.
  """
  @spec trust_confirm(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def trust_confirm(%Scope{} = scope, args) do
    with {:ok, subject} <- Tools.require_string(args, "subject") do
      subject
      |> Trust.confirm(authority: Authority.from_scope(scope), actor: actor(scope))
      |> decided(:confirmed)
    end
  end

  @doc """
  Dismiss an automatic suspension of `subject` as a false positive, with a
  recorded `reason` (`Arbiter.Loop.Trust.dismiss/3`): the suspension ends and the
  tier it never changed returns. Not a promotion. Coordinator only.
  """
  @spec trust_dismiss(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def trust_dismiss(%Scope{} = scope, args) do
    with {:ok, subject} <- Tools.require_string(args, "subject") do
      subject
      |> Trust.dismiss(Tools.fetch_string(args, "reason"),
        authority: Authority.from_scope(scope),
        actor: actor(scope)
      )
      |> decided(:dismissed)
    end
  end

  defp parse(subject) do
    case Trust.parse_subject(subject) do
      {:ok, key} -> {:ok, key}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp decided({:ok, record}, verb) do
    {:ok, detail} = View.detail(Trust.key(record))
    {:ok, %{verb => true, subject: detail}}
  end

  defp decided({:error, {:operator_only, message}}, _verb), do: {:error, {:forbidden, message}}
  defp decided({:error, {kind, message}}, _verb), do: {:error, {kind, message}}

  defp actor(scope), do: Arbiter.PaperTrail.actor_label(scope) || "coordinator"
end
