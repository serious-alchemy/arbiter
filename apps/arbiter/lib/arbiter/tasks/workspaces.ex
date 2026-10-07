defmodule Arbiter.Tasks.Workspaces do
  @moduledoc """
  The one rule for "which workspace does this call mean?" — shared by REST,
  MCP and the CLI's server side (parity audit bd-ws8nmk P-04; operator ruling
  on bd-26s98f).

      resolve(scope, arg, mode: :read | :write) :: {:ok, id | nil} | {:error, _}

  `arg` is what the caller named — a workspace **id or name**, `nil`/blank when
  it named nothing. `scope` is the caller's `Arbiter.MCP.Scope` (`nil` for an
  unauthenticated loopback caller, which is unbound).

  ## The decision

    1. **A named workspace** is looked up by id, then by name. Unknown is
       `{:error, {:not_found, _}}` (404) — never an empty result.
    2. **A bound scope is always confined.** A scope carrying a `workspace_id`
       (every worker, a refine token, a legacy workspace-bound coordinator) may
       only resolve to that workspace; naming another is
       `{:error, {:unauthorized, _}}` (403 over REST, -32003 over MCP). With
       nothing named, a bound scope resolves to its own workspace.
    3. **Nothing named, unbound scope:**
       * `mode: :read` → `{:ok, nil}`: **all workspaces**. The caller must echo
         the resolved scope (`workspace_id`, `nil` for all) in its response.
       * `mode: :write` → the sole workspace when there is exactly one, else
         `{:error, {:invalid, "multiple workspaces; pass workspace (name or id): …"}}`
         listing the candidates. A write **never** falls back to the workspace
         that happens to be named `default`.

  Everything that used to answer this question privately —
  `MCP.Tools.authorized_workspace/2` / `resolve_workspace_id/2`,
  `Quota.default_workspace_id/0`, `Loop.fetch_workspace/1`,
  `RepoSource.resolve/2`, the controllers' id-only lookups — delegates here.

  `default/0` is the one remaining "installation default" notion (sole
  workspace, else the one named `default`). It exists for single-workspace
  *displays* (the quota payload, the quota bar) and internal pipeline writes
  that have no caller; it is not a resolution rule for a request.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  @type mode :: :read | :write
  @type error ::
          {:not_found, String.t()} | {:unauthorized, String.t()} | {:invalid, String.t()}

  @doc """
  Resolve to a workspace id. `{:ok, nil}` means "all workspaces" and only ever
  comes back for `mode: :read`.
  """
  @spec resolve(Scope.t() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, error()}
  def resolve(scope, arg, opts \\ []) do
    with {:ok, ws} <- resolve_workspace(scope, arg, opts) do
      {:ok, ws && ws.id}
    end
  end

  @doc """
  Like `resolve/3` but hands back the `%Workspace{}` row (`nil` for "all"), for
  callers that need the config as well as the id.
  """
  @spec resolve_workspace(Scope.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Workspace.t() | nil} | {:error, error()}
  def resolve_workspace(scope, arg, opts \\ []) do
    mode = Keyword.get(opts, :mode, :read)
    bound = bound_id(scope)

    case normalize(arg) do
      nil -> resolve_omitted(bound, mode)
      ref -> resolve_named(bound, ref)
    end
  end

  @doc """
  For reads whose payload is shaped around ONE workspace (the quota view):
  the named / bound workspace, else `default/0`. Unlike `:write` mode this
  tolerates several workspaces — a quota lookup changes nothing — but it still
  confines a bound scope and 404s an unknown name.
  """
  @spec resolve_default(Scope.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, error()}
  def resolve_default(scope, arg) do
    case resolve(scope, arg, mode: :read) do
      {:ok, id} when is_binary(id) ->
        {:ok, id}

      {:ok, nil} ->
        case default_id() do
          {:ok, id} ->
            {:ok, id}

          {:error, :no_workspaces} ->
            {:error, {:invalid, "no workspaces exist on this installation"}}

          {:error, :ambiguous_workspace} ->
            {:error, {:invalid, ambiguous_message()}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The workspace reference in a REST/MCP params map: `"workspace"` (name or id)
  first, `"workspace_id"` as its alias. Blank is `nil`.
  """
  @spec arg(map()) :: String.t() | nil
  def arg(params) when is_map(params) do
    normalize(Map.get(params, "workspace")) || normalize(Map.get(params, "workspace_id"))
  end

  @doc "Look a workspace up by id, then by name; no scope check."
  @spec fetch(String.t()) :: {:ok, Workspace.t()} | {:error, {:not_found, String.t()}}
  def fetch(ref) when is_binary(ref) do
    with :error <- by_id(ref),
         :error <- by_name(ref) do
      {:error, {:not_found, "workspace #{inspect(ref)} not found"}}
    end
  end

  @doc """
  The installation default workspace: the lone workspace, else the one named
  `default`. **Not** a request-resolution rule (see the moduledoc).
  """
  @spec default() :: {:ok, Workspace.t()} | {:error, :no_workspaces | :ambiguous_workspace}
  def default do
    case Ash.read!(Workspace) do
      [%Workspace{} = ws] -> {:ok, ws}
      [] -> {:error, :no_workspaces}
      many -> default_named(many)
    end
  rescue
    _ -> {:error, :no_workspaces}
  end

  @doc "`default/0`'s id."
  @spec default_id() :: {:ok, String.t()} | {:error, :no_workspaces | :ambiguous_workspace}
  def default_id do
    with {:ok, %Workspace{id: id}} <- default(), do: {:ok, id}
  end

  # ---- internals ---------------------------------------------------------

  defp resolve_omitted(bound, _mode) when is_binary(bound), do: fetch_bound(bound)
  defp resolve_omitted(nil, :read), do: {:ok, nil}

  defp resolve_omitted(nil, :write) do
    case Ash.read!(Workspace) do
      [%Workspace{} = ws] ->
        {:ok, ws}

      [] ->
        {:error, {:invalid, "no workspaces exist on this installation"}}

      many ->
        {:error, {:invalid, ambiguous_message(many)}}
    end
  end

  defp ambiguous_message(workspaces \\ nil) do
    names =
      (workspaces || Ash.read!(Workspace))
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.join(", ")

    "multiple workspaces; pass workspace (name or id): #{names}"
  end

  defp resolve_named(bound, ref) do
    with {:ok, ws} <- fetch(ref) do
      if is_nil(bound) or bound == ws.id,
        do: {:ok, ws},
        else: {:error, {:unauthorized, "this scope is bound to a single workspace"}}
    end
  end

  defp fetch_bound(id) do
    case by_id(id) do
      {:ok, ws} -> {:ok, ws}
      :error -> {:error, {:not_found, "workspace #{inspect(id)} not found"}}
    end
  end

  defp by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_named(workspaces) do
    case Enum.find(workspaces, &(&1.name == "default")) do
      %Workspace{} = ws -> {:ok, ws}
      nil -> {:error, :ambiguous_workspace}
    end
  end

  defp bound_id(%Scope{workspace_id: id}) when is_binary(id) and id != "", do: id
  defp bound_id(_scope), do: nil

  defp normalize(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil
end
