defmodule Arbiter.Tasks.PermissionDecision do
  @moduledoc """
  The answer to a permission request (`docs/design/guardrail-profiles.md` §5.6,
  bd-lozakf, G15b): `grant/3` and `deny/3`, behind the MCP tool
  `ticket_permission_grant`, `POST /api/issues/:id/permission` and
  `arb ticket permit`.

  The decision itself is `Arbiter.Tasks.Permissions.grant/3` / `deny/3`: it is
  checked against the binding's `grant_by` through `Arbiter.Guardrails.Authority`
  (an operator-only binding needs operator proof, which an MCP coordinator token
  does not carry), changes the ticket's `permissions`, and writes the
  `granted` / `denied` row to `permission_events` with the actor. This module
  adds what a mid-run decision needs around it:

    * **a `network:` grant is live.** The egress proxy reads grants through
      `Arbiter.Worker.Egress.GrantCache`; `Egress.invalidate_grants/1` drops the
      task's cached list so the running worker's next `CONNECT` re-reads it. No
      restart.
    * **an env or mount grant waits for the next spawn.** Nothing in a running
      process's environment or jail can change. A resume dispatches again, and a
      dispatch projects the ticket's in-force permissions afresh
      (`Arbiter.Worker.Withholding.for_spawn/5`), so the grant arrives with it.
    * **the worker is told.** A denial reaches the worker's inbox with its reason
      (a worker that carries on without the permission should know why); a grant
      says how it takes effect.
    * **the request's attention clears** once nothing is pending on the ticket.

  Errors are `{kind, message}` for `Arbiter.Errors`: `:forbidden` when the
  authority may not decide it, `:conflict` when nothing is pending, `:invalid`
  for a malformed permission or a denial with no reason.
  """

  require Logger

  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Worker.Egress

  @type opts :: Permissions.opts()
  @type result :: %{
          permission: String.t(),
          decision: :granted | :denied,
          issue: Issue.t(),
          effect: :live | :next_spawn | :none
        }
  @type error :: {:forbidden | :conflict | :invalid, String.t()}

  @doc """
  Grant a pending (or suggested) `permission` on `issue`. Needs `:authority`;
  `:actor` and `:reason` go to the audit row.
  """
  @spec grant(Issue.t(), term(), opts()) :: {:ok, result()} | {:error, error()}
  def grant(%Issue{} = issue, permission, opts) do
    decide(issue, permission, opts, :granted)
  end

  @doc "Deny a pending (or suggested) `permission`. A `:reason` is required: the worker reads it."
  @spec deny(Issue.t(), term(), opts()) :: {:ok, result()} | {:error, error()}
  def deny(%Issue{} = issue, permission, opts) do
    with {:ok, reason} <- require_reason(Keyword.get(opts, :reason)) do
      decide(issue, permission, Keyword.put(opts, :reason, reason), :denied)
    end
  end

  @doc """
  The one entry point the MCP tool, `POST /api/issues/:id/permission` and
  `arb ticket permit` share: `deny?` picks `deny/3` over `grant/3`.
  """
  @spec answer(Issue.t(), term(), boolean(), opts()) :: {:ok, map()} | {:error, error()}
  def answer(%Issue{} = issue, permission, deny?, opts) do
    result = if deny?, do: deny(issue, permission, opts), else: grant(issue, permission, opts)

    with {:ok, decided} <- result, do: {:ok, view(decided)}
  end

  @doc "The wire shape of a decision."
  @spec view(result()) :: map()
  def view(%{permission: permission, decision: decision, issue: issue, effect: effect}) do
    %{
      id: issue.id,
      permission: permission,
      decision: Atom.to_string(decision),
      effect: Atom.to_string(effect),
      permissions: issue.permissions || [],
      pending_permissions: Permissions.pending(issue),
      message: effect_message(permission, decision, effect)
    }
  end

  defp effect_message(permission, :granted, :live),
    do: "#{permission} granted; the running worker's next connection to that host goes through."

  defp effect_message(permission, :granted, _),
    do:
      "#{permission} granted; it reaches the worker at its next spawn (resume it: " <>
        "`arb worker resume`). Nothing in a running process changes."

  defp effect_message(permission, :denied, _),
    do: "#{permission} denied; the worker was told why in its inbox."

  defp decide(issue, permission, opts, decision) do
    authority = Keyword.fetch!(opts, :authority)

    with {:ok, %{canonical: canonical, kind: kind}} <- parse(permission),
         :ok <- authorize(canonical, authority, issue),
         {:ok, updated} <- settle(issue, canonical, opts, decision) do
      effect = effect(kind, decision)
      apply_effect(updated, kind)
      clear_attention(updated)
      notify(updated, canonical, decision, effect, opts)

      {:ok, %{permission: canonical, decision: decision, issue: updated, effect: effect}}
    end
  end

  defp parse(permission) do
    case Vocabulary.parse(permission) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp authorize(canonical, authority, issue) do
    block = Permissions.workspace_block(issue.workspace_id)

    case Vocabulary.authorize_decision(canonical, authority, block) do
      :ok -> :ok
      {:error, message} -> {:error, {:forbidden, message}}
    end
  end

  defp settle(issue, canonical, opts, decision) do
    result =
      case decision do
        :granted -> Permissions.grant(issue, canonical, opts)
        :denied -> Permissions.deny(issue, canonical, opts)
      end

    case result do
      {:ok, updated} -> {:ok, updated}
      {:error, message} -> {:error, {error_kind(message), message}}
    end
  end

  defp error_kind(message) do
    if String.contains?(message, "nothing to decide"), do: :conflict, else: :invalid
  end

  defp require_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, {:invalid, "a denial needs a `reason`: the worker reads it"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_reason(_),
    do: {:error, {:invalid, "a denial needs a `reason`: the worker reads it"}}

  # A network host is the only reach a running process can gain. Everything else
  # the permission projects (env, mounts, tunnels, the ssh agent) is fixed at spawn.
  defp effect(:network, _decision), do: :live
  defp effect(:phi_data, _decision), do: :none
  defp effect(_kind, :granted), do: :next_spawn
  defp effect(_kind, :denied), do: :none

  # Granting and denying both drop the cache: a denial of a host that was
  # carried must stop it at once, and the cost of a redundant reload is one query.
  defp apply_effect(%Issue{id: id}, :network), do: Egress.invalidate_grants(id)
  defp apply_effect(_issue, _kind), do: :ok

  # The request is answered once nothing is waiting on a decision.
  defp clear_attention(%Issue{id: id} = issue) do
    with %Issue{attention_cause: :permission_requested} <- Ash.get!(Issue, id),
         [] <- Permissions.pending(issue) do
      Attention.clear(id, :permission_decided)
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "PermissionDecision: could not clear attention on #{issue.id}: #{inspect(e)}"
      )

      :ok
  end

  defp notify(issue, canonical, decision, effect, opts) do
    actor = Keyword.get(opts, :actor) || "coordinator"

    attrs = %{
      kind: :direction,
      workspace_id: issue.workspace_id,
      to_ref: issue.id,
      from_ref: "coordinator",
      task_ref: issue.id,
      subject: "#{canonical} #{decision}",
      body: body(canonical, decision, effect, actor, Keyword.get(opts, :reason))
    }

    case Message.send_mail(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("PermissionDecision: no notice sent: #{inspect(reason)}")
    end
  end

  defp body(canonical, :denied, _effect, actor, reason) do
    "Your request for `#{canonical}` was denied by #{actor}: #{reason}\n\n" <>
      "Nothing about this run changed. Carry on without it, or stop and report the " <>
      "affected acceptance criteria as unmet."
  end

  defp body(canonical, :granted, :live, actor, reason) do
    "`#{canonical}` was granted by #{actor}#{why(reason)}. It is live now: your next " <>
      "connection to that host goes through; no restart."
  end

  defp body(canonical, :granted, _effect, actor, reason) do
    "`#{canonical}` was granted by #{actor}#{why(reason)}. It reaches a run at spawn, " <>
      "so it is not in this process's environment: it arrives when the run is resumed."
  end

  defp why(reason) when is_binary(reason) and reason != "", do: " (#{reason})"
  defp why(_), do: ""
end
