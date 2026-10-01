defmodule Arbiter.TicketTransitionsInvariant do
  @moduledoc """
  The `ticket_transitions` invariant (bd-5gkqdr, reports design v2 §4.2): for
  every ticket, the last transition row's `to_state` is the ticket's stored
  `state`. Every report reads state history from that table, so a write that
  moves `state` without a row (or a row without the write) breaks this.
  """

  import ExUnit.Assertions

  alias Arbiter.Repo

  # "Last" is the latest `at`, ties broken by insertion order.
  @mismatches """
  SELECT i.id, i.state, (
    SELECT t.to_state FROM ticket_transitions t
    WHERE t.ticket_id = i.id
    ORDER BY t.at DESC, t.rowid DESC
    LIMIT 1
  ) AS last_to_state
  FROM issues i
  WHERE i.workspace_id = ?
  """

  @doc "Asserts the invariant for every ticket in `workspace_id`; returns how many were checked."
  @spec assert_holds!(String.t()) :: non_neg_integer()
  def assert_holds!(workspace_id) do
    %{rows: rows} = Repo.query!(@mismatches, [workspace_id])

    assert rows != [], "no tickets in workspace #{workspace_id} to check"

    mismatches = for [id, state, last] <- rows, state != last, do: {id, state, last}

    assert mismatches == [],
           "tickets whose last transition does not end in their state " <>
             "({id, state, last to_state}): #{inspect(mismatches)}"

    length(rows)
  end
end
