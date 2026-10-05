defmodule Arbiter.Tasks.History do
  @moduledoc """
  A ticket's recent audit history — the `Arbiter.Tasks.Issue.Version` rows —
  shaped for display, with who made each write (`Arbiter.Actor.of_version/1`,
  bd-6i7yzq). Read by `GET /api/issues/:id` (so `arb show` prints it).
  """

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.Tasks.Issue.Version

  @default_limit 10

  @type entry :: %{
          at: DateTime.t(),
          action: String.t(),
          actor: String.t() | nil,
          changes: map()
        }

  @doc "The `limit` most recent versions of `issue_id`, newest first."
  @spec recent(String.t(), pos_integer()) :: [entry()]
  def recent(issue_id, limit \\ @default_limit) when is_binary(issue_id) do
    Version
    |> Ash.Query.filter(version_source_id == ^issue_id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
    |> Enum.map(fn v ->
      %{
        at: v.version_inserted_at,
        action: to_string(v.version_action_name),
        actor: Actor.of_version(v),
        changes: v.changes || %{}
      }
    end)
  end
end
