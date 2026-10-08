defmodule ArbiterWeb.Api.SkillJSON do
  @moduledoc """
  Render functions for `Arbiter.Skills.Skill` resources. The shapes live in
  `Arbiter.Skills.Serializer`, shared with the MCP tools (parity audit P-22):
  a list omits `body`, a single skill carries it.
  """

  alias Arbiter.Skills.Serializer

  def index(%{skills: skills}), do: %{data: Serializer.summaries(skills)}

  # `show` optionally carries a non-fatal bundled-collision warning (create /
  # update); it is omitted entirely when there is no collision.
  def show(%{skill: skill} = assigns) do
    case Map.get(assigns, :warning) do
      nil -> Serializer.full(skill)
      warning -> Map.put(Serializer.full(skill), :warning, warning)
    end
  end
end
