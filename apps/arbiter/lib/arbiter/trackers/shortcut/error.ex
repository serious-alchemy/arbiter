defmodule Arbiter.Trackers.Shortcut.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Shortcut` function on
  failure. Mirrors `Arbiter.Trackers.Jira.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, story/workflow doesn't exist
    * `:validation_failed` — 400/422, Shortcut rejected the body
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_not_found` — the requested tracker status had no mapping to a
      Shortcut workflow state available in the configured workflow(s)
    * `:upstream_past_target` — a forward transition was declined because the
      item is already at, or beyond, the mapped state (bd-4i7kky);
      writing would move it backwards
    * `:config_missing` — workspace config is missing credentials, or no active
      workspace is set
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
          | :transition_not_found
          | :upstream_past_target
          | :config_missing

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
