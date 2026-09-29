defmodule Arbiter.Tasks.Issue.Changes.GuardState do
  @moduledoc """
  The state preconditions of the two Issue actions that are not lifecycle
  transitions, so `Changes.Transition` does not check them:

    * `:record_verification` (bd-9so315) — the ticket must be `:verifying`;
      there is no verdict to record otherwise.
    * `:sync_upstream_close` — the ticket must already be `:closed`. The
      action makes no local change; it only pushes a close to the linked
      tracker for a ticket that closed without `close_upstream: true`.

  Every transition action (`:close`, `:reopen`, `:await_verification`, …) is
  checked against `Arbiter.Tasks.Lifecycle`'s table by `Changes.Transition`
  instead. bd-36ytcl replaced the legacy status FSM this module used to
  enforce for them.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @required %{record_verification: :verifying, sync_upstream_close: :closed}

  @impl true
  def change(changeset, opts, _context) do
    action = Keyword.fetch!(opts, :action)
    required = Map.fetch!(@required, action)

    Changeset.before_action(changeset, fn cs ->
      if cs.data.state == required,
        do: cs,
        else:
          Changeset.add_error(cs,
            field: :state,
            message:
              "Cannot #{action} a ticket that is #{inspect(cs.data.state)} " <>
                "(it must be #{inspect(required)})."
          )
    end)
  end
end
