defmodule Arbiter.Tasks.PermissionRequest do
  @moduledoc """
  A worker asks for a permission mid-run (`docs/design/guardrail-profiles.md`
  §5.6, bd-dvqdcc): `submit/4`, behind the worker-tier MCP tool
  `permission_request`.

  A request **grants nothing**. It is validated against the workspace's
  `guardrails.bindings`, written to `permission_events` as `requested` (source
  `request`, with the run it came from), and raised as the
  `:permission_requested` attention through `Arbiter.Messages.Escalation.post/1`.
  The ticket's `permissions` are not touched, so the run's reach (egress, env,
  mounts) is exactly what it was.

  The attention is the coordinator's, or the operator's when the permission's
  `grant_by` (`Arbiter.Guardrails.Permissions.grant_by/2`) is `operator`.

  A request is not a trust violation: nothing here writes a `guardrail_events`
  row, and the `requested` event is what `Arbiter.Guardrails.Events.link_egress/2`
  reads to tell an asked-for host from an unrequested one.

  Errors are `{kind, message}` for `Arbiter.Errors`: `:invalid` for a malformed
  permission, one the workspace has no binding for, a data class, or a blank
  reason; `:conflict` for one the ticket already holds.
  """

  require Ash.Query

  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Messages.Escalation
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Workers.Run

  @type result :: %{
          permission: String.t(),
          grant_by: :operator | :coordinator,
          already_requested: boolean()
        }

  @doc """
  Record a request by `actor` (a label) for `permission` on `issue`, with the
  worker's `reason`. A permission that is already pending is not recorded
  twice: the result says `already_requested: true`.
  """
  @spec submit(Issue.t(), term(), term(), keyword()) ::
          {:ok, result()} | {:error, {:invalid | :conflict, String.t()}}
  def submit(%Issue{} = issue, permission, reason, opts \\ []) do
    block = Permissions.workspace_block(issue.workspace_id)

    with {:ok, reason} <- require_reason(reason),
         {:ok, parsed} <- parse(permission),
         :ok <- requestable(parsed, block),
         canonical = Vocabulary.required_form(parsed.canonical),
         :ok <- not_in_force(issue, canonical) do
      grant_by = Vocabulary.grant_by(canonical, block)

      if canonical in Permissions.pending(issue) do
        {:ok, %{permission: canonical, grant_by: grant_by, already_requested: true}}
      else
        record(issue, canonical, reason, grant_by, opts)
        {:ok, %{permission: canonical, grant_by: grant_by, already_requested: false}}
      end
    end
  end

  defp require_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, {:invalid, "`reason` is required: say what you need it for"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_reason(_),
    do: {:error, {:invalid, "`reason` is required: say what you need it for"}}

  defp parse(permission) do
    case Vocabulary.parse(permission) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  # A network host is a ticket grant: the workspace need not bind each one. Every
  # other action needs a binding to resolve to; a data class is not a grant at all.
  defp requestable(%{kind: :phi_data, canonical: canonical}, _block) do
    {:error,
     {:invalid,
      "#{canonical} is a data class, not something a worker can be granted: it restricts " <>
        "who may see the worktree. Ask the coordinator to add it to the ticket"}}
  end

  defp requestable(%{kind: :network}, _block), do: :ok

  defp requestable(parsed, block) do
    if Vocabulary.binding(block, parsed) do
      :ok
    else
      {:error,
       {:invalid,
        "#{parsed.canonical} has no binding in this workspace's guardrails.bindings, so there " <>
          "is nothing to grant. Tell the coordinator what you need with `arb message`"}}
    end
  end

  defp not_in_force(issue, canonical) do
    if canonical in Permissions.in_force(issue) do
      {:error, {:conflict, "#{canonical} is already granted on #{issue.id}: nothing to request"}}
    else
      :ok
    end
  end

  defp record(issue, canonical, reason, grant_by, opts) do
    actor = Keyword.get(opts, :actor)

    Permissions.record!(
      [%{permission: canonical, event: :requested}],
      issue.id,
      :request,
      actor: actor,
      reason: reason,
      run_id: current_run_id(issue.id)
    )

    raise_attention(issue, canonical, reason, grant_by)
  end

  defp raise_attention(issue, canonical, reason, grant_by) do
    subject = "#{issue.id} asks for #{canonical}"

    Escalation.post(%{
      kind: :permission_requested,
      workspace_id: issue.workspace_id,
      task_ref: issue.id,
      subject: subject,
      detail: subject,
      body:
        "#{issue.id} asked for `#{canonical}`: #{reason}\n\n" <>
          "Recorded, not granted: the run's reach is unchanged until #{grantor(grant_by)} " <>
          "grants it. Pending on the ticket: #{Enum.join(Permissions.pending(issue), ", ")}."
    })

    if grant_by == :operator do
      Attention.hand_off(
        issue.id,
        :operator,
        "#{canonical} is grant_by: operator; only the operator may grant it"
      )
    end

    :ok
  end

  defp grantor(:operator), do: "the operator"
  defp grantor(:coordinator), do: "the coordinator"

  # The run the request came from: the ticket's newest run.
  defp current_run_id(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%{id: id}] -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
