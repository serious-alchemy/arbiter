defmodule ArbiterWeb.Api.SkillController do
  @moduledoc """
  REST endpoints for the system-wide `Arbiter.Skills.Skill` registry
  (bd-cj6i08). Backs the `arb skill` CLI.

  Routes:

    * `GET    /api/skills`     — :index
    * `POST   /api/skills`     — :create
    * `GET    /api/skills/:id` — :show  (`:id` is a UUID or the skill name;
      a name resolves within the `workspace` param / bound token, scoped over global)
    * `PATCH  /api/skills/:id` — :update (also `PUT`)
    * `DELETE /api/skills/:id` — :delete

  A skill is global by default; pass `workspace_id` on create to scope it to a
  workspace (where it shadows a same-named global). `GET /api/skills` accepts an
  optional `workspace_id` query param to list a workspace's effective set.
  Writes are attributed to the `"cli"` actor in the paper-trail history.
  `create`/`update` responses include a non-fatal `warning` when the name
  collides with a bundled skill (spike bd-5tc1s0 finding #3).
  """

  use ArbiterWeb, :controller

  alias Arbiter.Skills
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback ArbiterWeb.Api.FallbackController

  # Attribution label for writes originating at the `arb` CLI / REST surface.
  @actor "cli"

  # bd-6i7yzq: the token's actor (`Arbiter.Actor`, installed by `ApiAuth`) when
  # there is one, else the surface's historical `"cli"` label.
  defp actor_label, do: Arbiter.Actor.resolve_label(nil) || @actor

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      skills =
        case ws_id do
          nil -> Skills.list_skills()
          ws_id -> Skills.list_skills(workspace_id: ws_id)
        end

      render(conn, :index, skills: skills)
    end
  end

  def show(conn, %{"id" => id} = params) do
    with {:ok, skill} <- fetch_in_scope(conn, id, params) do
      render(conn, :show, skill: skill)
    end
  end

  # By-name lookup honours the caller's workspace (`workspace` / `workspace_id`,
  # or the token's bound workspace), as MCP `skill_get` does: a scoped skill
  # shadows the global one, and a bound token never sees another workspace's.
  defp fetch_in_scope(conn, ref, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      Skills.fetch_skill_in_scope(ref, ws_id)
    end
  end

  def create(conn, params) do
    # A skill is global unless a workspace is named (id or name) — even a
    # workspace-bound token must ask for scoping, as in MCP `skill_create`.
    with {:ok, ws_id} <- named_workspace(conn, params) do
      attrs =
        params
        |> Map.take(["name", "body", "metadata", "activation_mode", "code_only"])
        |> then(fn attrs -> if ws_id, do: Map.put(attrs, "workspace_id", ws_id), else: attrs end)

      create_skill(conn, attrs)
    end
  end

  defp named_workspace(conn, params) do
    if Arbiter.Tasks.Workspaces.arg(params),
      do: WorkspaceParam.resolve(conn, params, :read),
      else: {:ok, nil}
  end

  defp create_skill(conn, attrs) do
    with {:ok, skill} <- Skills.create_skill(attrs, actor: actor_label()) do
      conn
      |> put_status(:created)
      |> render(:show, skill: skill, warning: Skills.bundled_collision(skill.name))
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = Map.take(params, ["name", "body", "metadata", "activation_mode", "code_only"])

    with {:ok, skill} <- fetch_in_scope(conn, id, params),
         {:ok, updated} <- Skills.update_skill(skill, attrs, actor: actor_label()) do
      render(conn, :show, skill: updated, warning: Skills.bundled_collision(updated.name))
    end
  end

  def delete(conn, %{"id" => id} = params) do
    with {:ok, skill} <- fetch_in_scope(conn, id, params),
         :ok <- Skills.delete_skill(skill) do
      json(conn, Arbiter.Skills.Serializer.deleted(skill))
    end
  end
end
