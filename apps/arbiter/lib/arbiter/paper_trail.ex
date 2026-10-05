defmodule Arbiter.PaperTrail do
  @moduledoc """
  Helpers for the `AshPaperTrail`-versioned resources (`Issue`, `Skill`,
  `Workspace`).

  ## Actor attribution

  `ash_paper_trail`'s `belongs_to_actor` DSL requires the actor to be an Ash
  *resource* (it stores a foreign key to a `User`-like row). arbiter has no such
  resource — a write originates from an MCP `Arbiter.MCP.Scope` (a coordinator
  or a worker bound to one task), the `arb` CLI, or the dashboard. So instead of
  a relationship we record a **stable string label** for the actor and let
  `paper_trail`'s `attributes_as_attributes` snapshot it onto every version row
  (see `Arbiter.Skills.Skill` / `Arbiter.Tasks.Workspace`).

  `actor_label/1` normalises whatever the caller threads through as the Ash
  `actor:` option into that label:

    * an `Arbiter.Actor` → its `Actor.label/1`
    * a coordinator scope → `"coordinator"` (`"operator:cli"` for an
      operator-proof token), a worker scope → `"worker:<task_id>"`, a refine
      scope → `"refine:<bound issue id>"` (all via `Arbiter.Actor.from_scope/1`)
    * a bare string (e.g. `"cli"`, `"dashboard"`) → itself
    * `nil` → `nil` (an unattributed write, e.g. a seed or a legacy caller)
  """

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope

  @doc """
  Normalise an Ash `actor` term into a stable string label for a version row.
  """
  @spec actor_label(term()) :: String.t() | nil
  def actor_label(%Actor{} = actor), do: Actor.label(actor)

  def actor_label(%Scope{} = scope) do
    case Actor.from_scope(scope) do
      %Actor{} = actor -> Actor.label(actor)
      nil -> nil
    end
  end

  def actor_label(label) when is_binary(label), do: label
  def actor_label(nil), do: nil
  def actor_label(other), do: inspect(other)
end
