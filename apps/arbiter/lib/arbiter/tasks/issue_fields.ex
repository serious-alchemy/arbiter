defmodule Arbiter.Tasks.IssueFields do
  @moduledoc """
  The coordinator-writable field allow-list for `Issue :create` / `:update`
  (P-14, D-T-5/6/34).

  `Issue`'s accept lists are wider than what a person or an LLM coordinator
  should be able to set: they also carry ReviewPatrol / PRPatrol engagement
  state (`last_verdict*`, `review_count`, `posted_findings`, …), the circuit
  breaker (`circuit_breaker_*`), the `pr_opened_*_ref` watermarks and the
  per-ticket `skills` override — all written by internal callers that go
  straight to the Ash action. This module is the one list of what the REST
  surface (and, by guard test, the MCP specs) may pass through.

    * `create_fields/0` / `update_fields/0` — the user-facing fields (the A2
      matrix in the parity audit). Lower tiers are narrowed *further* by
      `ArbiterWeb.ApiPolicy` before a request reaches the controller.
    * `denied/2` — the keys of a request that the Ash action accepts but this
      allow-list does not, plus `change_origin` (the audit label that
      `Arbiter.Actor.of_version/1` prefers over the real actor). Keys the
      action does not know at all are *not* reported here: they fall through to
      Ash, whose `NoSuchInput` is the existing 422 for an unknown key.
    * `check/2` — `denied/2` as a `{:error, {:invalid, message}}` (422 on REST,
      `isError` on MCP).

  The deliberate routes for the denied state:

    * clearing a tripped breaker — the typed `Issue :resume_review` action
      (`POST /api/issues/:id/resume_review`, MCP `ticket_resume_review`,
      `arb ticket update --resume-review`);
    * `change_origin` — `Arbiter.Loop.Apply` only, internally;
    * ReviewPatrol / PRPatrol / `pr_opened_*` — their own internal `Ash.update`
      calls and the named transition actions;
    * `permissions` (bd-54m4vv) — writable here, but only a coordinator or the
      operator gets anywhere: the controller / MCP tool hand the caller's
      authority to the `Issue` changes, which refuse a worker or refine token
      (`Arbiter.Guardrails.Permissions.plan/4`). Granting an operator-grant
      permission is `Arbiter.Tasks.Permissions.grant/3`, not a field write.
    * `skills` — not writable over REST/MCP/CLI. It is read only at dispatch
      (`Arbiter.Skills.Selection`); the resource attribute stays for internal
      seeding.
  """

  alias Arbiter.Tasks.Issue

  @shared ~w(title description acceptance notes qa_notes deployment_notes priority difficulty
             issue_type auto_close verify_after_deploy provider_constraint permissions tracker_type
             tracker_ref tracker_context_type tracker_context_ref target_branch repo)

  @create @shared ++
            ~w(workspace_id source_pr skip_upstream_create parent_id tracker_child_policy)

  @update @shared ++ ~w(pr_ref pr_body append_notes)

  @always_denied ~w(change_origin)

  @doc "Fields a coordinator may set on `POST /api/issues`."
  @spec create_fields() :: [String.t()]
  def create_fields, do: @create

  @doc "Fields a coordinator may set on `PATCH /api/issues/:id`."
  @spec update_fields() :: [String.t()]
  def update_fields, do: @update

  @doc "The allow-list for `action` (`:create` | `:update`)."
  @spec allowed(:create | :update) :: [String.t()]
  def allowed(:create), do: @create
  def allowed(:update), do: @update

  @doc """
  Keys of `params` that `action` accepts (or that are audit-only) but the
  allow-list does not. String keys; order follows `params`.
  """
  @spec denied(map(), :create | :update) :: [String.t()]
  def denied(params, action) when is_map(params) and action in [:create, :update] do
    allowed = allowed(action)
    governed = governed(action)

    params
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&((&1 in governed or &1 in @always_denied) and &1 not in allowed))
    |> Enum.sort()
  end

  @doc "`:ok`, or `{:error, {:invalid, message}}` naming every denied key."
  @spec check(map(), :create | :update) :: :ok | {:error, {:invalid, String.t()}}
  def check(params, action) do
    case denied(params, action) do
      [] ->
        :ok

      keys ->
        {:error,
         {:invalid,
          "#{Enum.join(keys, ", ")} #{if length(keys) == 1, do: "is", else: "are"} not writable " <>
            "on a ticket #{action} (internal review/breaker/audit state; use the typed " <>
            "operation, e.g. resume_review to clear a tripped breaker)"}}
    end
  end

  # Everything the Ash action takes: accepted attributes plus its arguments.
  defp governed(action) do
    action_struct = Ash.Resource.Info.action(Issue, action)

    accepted = action_struct.accept || []
    arguments = Enum.map(action_struct.arguments, & &1.name)

    Enum.map(accepted ++ arguments, &Atom.to_string/1)
  end
end
