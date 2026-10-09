defmodule Arbiter.Tasks.Permissions do
  @moduledoc """
  A ticket's declared permissions and their audit trail
  (`docs/design/guardrail-profiles.md` §5.2–5.3): the DB-facing half of
  `Arbiter.Guardrails.Permissions`.

  `issues.permissions` is what the ticket *carries*. Whether each entry is **in
  force** is read off `permission_events`: a permission whose latest event is
  `requested` is **pending** — a coordinator declared something whose `grant_by`
  is `operator` (§5.3 (2)), or a worker asked for it (§5.6) — and gives no
  reach until it is granted. `in_force/1` is what dispatch and routing (G13,
  G14) read; `pending/1` is what the card hold `{:guardrail, "awaiting
  operator grant: …"}` names.

    * `grant/3` / `deny/3` — settle a pending (or suggested) permission, checked
      against the binding's `grant_by`.
    * `suggest/3` — record a `suggested` event. Inference (refine, coordinator
      tooling) only ever suggests; a suggestion changes nothing until someone with
      authority grants it (§5.3 (3)).
    * `record!/3` — what the Issue changes use to write the planned events.

  All functions that decide take an explicit `:authority`
  (`:operator | :coordinator | :restricted`, `Arbiter.Guardrails.Authority`) —
  there is no default, so an untrusted entry point can't inherit operator.
  """

  require Ash.Query

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Guardrails.Config
  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PermissionEvent
  alias Arbiter.Tasks.Workspace

  @type opts :: [
          authority: Authority.authority(),
          actor: String.t() | nil,
          reason: String.t() | nil,
          run_id: String.t() | nil
        ]

  # ---- reading -----------------------------------------------------------------

  @doc "Every event for the ticket, oldest first."
  @spec events(Issue.t() | String.t()) :: [PermissionEvent.t()]
  def events(%Issue{id: id}), do: events(id)

  def events(issue_id) when is_binary(issue_id) do
    PermissionEvent
    |> Ash.Query.filter(issue_id == ^issue_id)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!()
  end

  @doc "Permissions whose latest event is `requested`: carried, but not yet granted."
  @spec pending(Issue.t()) :: [String.t()]
  def pending(%Issue{} = issue), do: for({p, :requested} <- latest(issue), do: p) |> Enum.sort()

  @doc "The ticket's permissions that are in force: carried and not pending."
  @spec in_force(Issue.t()) :: [String.t()]
  def in_force(%Issue{permissions: permissions} = issue), do: permissions -- pending(issue)

  defp latest(issue) do
    issue
    |> events()
    |> Enum.reduce(%{}, fn e, acc -> Map.put(acc, e.permission, e.event) end)
    |> Map.to_list()
  end

  # ---- writing events ------------------------------------------------------------

  @doc """
  Append one event per planned entry (`%{permission:, event:}`) for `issue_id`,
  all with `source`. `opts`: `:actor`, `:reason`, `:run_id`.
  """
  @spec record!([map()], String.t(), atom(), keyword()) :: :ok
  def record!(planned, issue_id, source, opts \\ []) do
    for p <- planned do
      Ash.create!(PermissionEvent, %{
        issue_id: issue_id,
        permission: p.permission,
        event: p.event,
        source: Map.get(p, :source, source),
        actor: opts[:actor],
        reason: opts[:reason],
        run_id: opts[:run_id]
      })
    end

    :ok
  end

  # ---- deciding ------------------------------------------------------------------

  @doc """
  Record that `permission` is suggested for `issue` (source `refine`). Changes
  nothing else: it is not carried by the ticket and gives no reach.
  """
  @spec suggest(Issue.t(), String.t(), keyword()) :: {:ok, Issue.t()} | {:error, String.t()}
  def suggest(%Issue{} = issue, permission, opts) do
    with {:ok, %{canonical: canonical}} <- Vocabulary.parse(permission) do
      record!([%{permission: canonical, event: :suggested}], issue.id, :refine, opts)
      {:ok, issue}
    end
  end

  @doc """
  Grant a `requested` or `suggested` permission. Needs the binding's `grant_by`
  authority (`:operator` for `prod_ssh`, …). Puts the permission on the ticket
  if it is not carried yet, and records `granted`.
  """
  @spec grant(Issue.t(), String.t(), opts()) :: {:ok, Issue.t()} | {:error, String.t()}
  def grant(%Issue{} = issue, permission, opts) do
    decide(issue, permission, opts, :granted, fn permissions, canonical ->
      Enum.sort(Enum.uniq([canonical | permissions]))
    end)
  end

  @doc "Deny a `requested` or `suggested` permission: off the ticket, `denied` recorded."
  @spec deny(Issue.t(), String.t(), opts()) :: {:ok, Issue.t()} | {:error, String.t()}
  def deny(%Issue{} = issue, permission, opts) do
    decide(issue, permission, opts, :denied, fn permissions, canonical ->
      permissions -- [canonical]
    end)
  end

  defp decide(issue, permission, opts, event, update_fun) do
    authority = Keyword.fetch!(opts, :authority)
    block = workspace_block(issue.workspace_id)

    with {:ok, %{canonical: canonical}} <- Vocabulary.parse(permission),
         :ok <- Vocabulary.authorize_decision(canonical, authority, block),
         :ok <- decidable(issue, canonical),
         {:ok, updated} <-
           issue
           |> Ash.Changeset.for_update(:set_permissions, %{
             permissions: update_fun.(issue.permissions, canonical)
           })
           |> Ash.update()
           |> wrap_error() do
      record!([%{permission: canonical, event: event}], issue.id, :system, opts)
      {:ok, updated}
    end
  end

  defp decidable(issue, canonical) do
    case List.keyfind(latest(issue), canonical, 0) do
      {_, event} when event in [:requested, :suggested] ->
        :ok

      _ ->
        {:error, "#{canonical} is not requested or suggested on #{issue.id}: nothing to decide"}
    end
  end

  defp wrap_error({:ok, _} = ok), do: ok
  defp wrap_error({:error, err}), do: {:error, Exception.message(err)}

  # ---- shared with the Issue changes ----------------------------------------------

  @doc "The workspace's string-keyed `guardrails` block (`%{}` when it has none)."
  @spec workspace_block(String.t() | nil) :: map()
  def workspace_block(nil), do: %{}

  def workspace_block(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> Config.block(ws)
      _ -> %{}
    end
  end
end
