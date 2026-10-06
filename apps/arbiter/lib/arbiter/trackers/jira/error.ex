defmodule Arbiter.Trackers.Jira.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Jira` function on
  failure. Mirrors the shape of `Arbiter.GitHub.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, issue/transition doesn't exist
    * `:validation_failed` — 400/422, Jira rejected the body
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_unavailable` — no live transition lands on a planned
      workflow-graph hop's destination status (the configured route passes
      through a status the issue can't reach from where it is)
    * `:no_transition_path` — the target status is mapped, but no route to it
      exists in the configured `transition_graph`
    * `:upstream_past_target` — a forward transition was declined because the
      ticket is not known to still precede the mapped status (it may
      have been moved past it by someone else); writing would move it backwards
    * `:status_unmapped` — the lifecycle event has no `status_map` entry; a
      benign "this tracker doesn't model that" skip
    * `:config_missing` — workspace config is missing host / project_key /
      credentials, or no active workspace is set
  """

  defstruct [:kind, :status, :message, :raw]

  @type kind ::
          :unauthenticated
          | :forbidden
          | :not_found
          | :validation_failed
          | :server_error
          | :http
          | :network
          | :transition_unavailable
          | :no_transition_path
          | :upstream_past_target
          | :status_unmapped
          | :config_missing

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
