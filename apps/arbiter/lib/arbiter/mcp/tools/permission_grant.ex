defmodule Arbiter.MCP.Tools.PermissionGrant do
  @moduledoc """
  `Arbiter.MCP.Tools` handler for `ticket_permission_grant` (G15b, bd-lozakf;
  `docs/design/guardrail-profiles.md` §5.6): the coordinator's answer to a
  worker's `permission_request`, or a grant it decides on its own.

  The authority is the token's (`Arbiter.Guardrails.Authority.from_scope/1`). An
  MCP coordinator token never carries operator proof, so a permission whose
  binding says `grant_by: operator` is refused here and answered with
  `arb ticket permit` from the operator's own shell.
  """

  alias Arbiter.Guardrails.Authority
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.PaperTrail
  alias Arbiter.Tasks.PermissionDecision

  @spec ticket_permission_grant(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_permission_grant(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         {:ok, deny?} <- Tools.fetch_bool(args, "deny", false) do
      PermissionDecision.answer(issue, Map.get(args, "permission"), deny?,
        authority: Authority.from_scope(scope),
        actor: PaperTrail.actor_label(scope),
        reason: Map.get(args, "reason")
      )
      |> operator_hint()
    end
  end

  defp operator_hint({:error, {:forbidden, message}}) do
    if String.contains?(message, "grant_by: operator") do
      {:error,
       {:forbidden,
        message <>
          ". An operator-only permission is decided from the operator's shell with " <>
          "`arb ticket permit` (operator proof), never over MCP"}}
    else
      {:error, {:forbidden, message}}
    end
  end

  defp operator_hint(other), do: other
end
