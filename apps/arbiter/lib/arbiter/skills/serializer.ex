defmodule Arbiter.Skills.Serializer do
  @moduledoc """
  The one wire shape for a skill (parity audit P-22), shared by REST
  (`ArbiterWeb.Api.SkillJSON`) and MCP (`Arbiter.MCP.Tools.Skills`):

    * `summary/2` — what a LIST returns: every field except the markdown `body`;
    * `full/2` — what `show` / `create` / `update` return: the summary plus `body`;
    * `deleted/1` — what a DELETE returns: `%{deleted: true, id, name}`.

  Usage counters are always part of the shape; pass the skill's
  `Arbiter.Skills.Usage` row, or let it default to zeros.
  """

  require Ash.Query

  alias Arbiter.Skills.Skill
  alias Arbiter.Skills.Usage

  @doc "List-row shape (no `body`)."
  @spec summary(Skill.t(), Usage.t() | nil) :: map()
  def summary(%Skill{} = skill, usage \\ nil) do
    usage = usage || empty_usage()

    %{
      id: skill.id,
      name: skill.name,
      workspace_id: skill.workspace_id,
      scope: if(is_nil(skill.workspace_id), do: "global", else: "workspace"),
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: iso(skill.created_at),
      updated_at: iso(skill.updated_at),
      materialize_count: usage.materialize_count,
      invoke_count: usage.invoke_count,
      patch_count: usage.patch_count,
      last_materialized_at: iso(usage.last_materialized_at),
      last_invoked_at: iso(usage.last_invoked_at),
      last_patched_at: iso(usage.last_patched_at)
    }
  end

  @doc "Single-skill shape: the summary plus `body`."
  @spec full(Skill.t(), Usage.t() | nil) :: map()
  def full(%Skill{} = skill, usage \\ nil),
    do: skill |> summary(usage || load_usage(skill.id)) |> Map.put(:body, skill.body)

  @doc "DELETE result."
  @spec deleted(Skill.t()) :: map()
  def deleted(%Skill{} = skill), do: %{deleted: true, id: skill.id, name: skill.name}

  @doc "List shape for many skills; usage rows are fetched in one query."
  @spec summaries([Skill.t()]) :: [map()]
  def summaries(skills) do
    usage = load_usage_by_skill_ids(Enum.map(skills, & &1.id))
    Enum.map(skills, &summary(&1, Map.get(usage, &1.id)))
  end

  defp load_usage(skill_id) do
    query = Ash.Query.filter(Usage, skill_id == ^skill_id)

    case Ash.read_one(query) do
      {:ok, %Usage{} = usage} -> usage
      _ -> empty_usage()
    end
  end

  defp load_usage_by_skill_ids([]), do: %{}

  defp load_usage_by_skill_ids(skill_ids) do
    Usage
    |> Ash.Query.filter(skill_id in ^skill_ids)
    |> Ash.read!()
    |> Map.new(&{&1.skill_id, &1})
  rescue
    _ -> %{}
  end

  defp empty_usage do
    %Usage{
      materialize_count: 0,
      invoke_count: 0,
      patch_count: 0,
      last_materialized_at: nil,
      last_invoked_at: nil,
      last_patched_at: nil
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
end
