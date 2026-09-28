defmodule ArbiterWeb.WorkspaceDetail.RepoPathsComponent do
  @moduledoc """
  `repo_paths` — repo name to local filesystem checkout path, used to resolve
  a dispatch's working directory.

  Both add and remove rewrite the whole map and pass `["repo_paths"]` as an
  unset path: deep-merge can't delete a key, and an entry may carry the richer
  `%{"path" => ..., "target_branch" => ...}` shape a sibling write must not
  flatten.
  """
  use ArbiterWeb, :live_component

  import ArbiterWeb.WorkspaceDetail.Rows
  import ArbiterWeb.WorkspaceDetail.Shared

  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Worker.Worktree
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:repo_path_error, nil)
     |> assign(:worktree_states, %{})
     |> assign(:worktree_error, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign(:repo_paths, socket.assigns.workspace |> repo_paths() |> Enum.sort())
     |> load_worktree_states()}
  end

  # Each state costs a `git status` in the repo, so it is recomputed only when
  # the set of paths actually changes — the parent re-renders this component on
  # every write anywhere on the page.
  #
  # bd-7p07gw: and it runs in a `start_async/3` task, never in `update/2`
  # itself — one slow or huge checkout used to hold the whole page. Until the
  # probe lands, a repo whose path is new chips `checking`; one whose path is
  # unchanged keeps the state it already had. Starting a probe under the same
  # name replaces one still in flight, so a stale result is never applied.
  defp load_worktree_states(socket) do
    paths = socket.assigns.repo_paths

    if socket.assigns[:worktree_of] == paths do
      socket
    else
      known = known_states(socket.assigns[:worktree_of] || [], socket.assigns.worktree_states)

      socket
      |> assign(:worktree_of, paths)
      |> assign(:worktree_error, nil)
      |> assign(
        :worktree_states,
        Map.new(paths, fn {repo, path} ->
          {repo, Map.get(known, {repo, path}, "checking")}
        end)
      )
      |> start_async(:worktree_states, fn ->
        Map.new(paths, fn {repo, path} -> {repo, worktree_state(path)} end)
      end)
    end
  end

  defp known_states(paths, states) do
    for {repo, path} <- paths,
        state = Map.get(states, repo),
        state not in [nil, "checking"],
        into: %{},
        do: {{repo, path}, state}
  end

  @impl true
  def handle_async(:worktree_states, {:ok, states}, socket) do
    {:noreply, assign(socket, :worktree_states, states)}
  end

  # The probe itself crashed (a per-path git failure is already `unknown`
  # inside it). The entries are still legitimate config, so they chip
  # `unknown` and the section says why, rather than taking the page down.
  def handle_async(:worktree_states, {:exit, reason}, socket) do
    Logger.error("RepoPathsComponent: worktree probe failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:worktree_states, Map.new(socket.assigns.repo_paths, &{elem(&1, 0), "unknown"}))
     |> assign(:worktree_error, describe_exit(reason))}
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # A path that isn't a git checkout, or isn't there at all, is `unknown`
  # rather than an error: the entry is still legitimate config, it just can't
  # be inspected from here.
  defp worktree_state(nil), do: "unknown"

  defp worktree_state(path) do
    case Worktree.has_uncommitted?(Path.expand(path)) do
      {:ok, true} -> "dirty"
      {:ok, false} -> "clean"
      _ -> "unknown"
    end
  end

  @impl true
  def handle_event("add_repo_path", %{"repo_path" => %{"repo" => repo, "path" => path}}, socket) do
    repo = String.trim(repo || "")
    path = String.trim(path || "")

    cond do
      repo == "" ->
        {:noreply, assign(socket, :repo_path_error, "Repo name can't be empty.")}

      path == "" ->
        {:noreply, assign(socket, :repo_path_error, "Repo path can't be empty.")}

      true ->
        existing = repo_paths_raw(socket.assigns.workspace)

        entry =
          case Map.get(existing, repo) do
            %{} = m -> Map.put(m, "path", path)
            _ -> path
          end

        write(socket, Map.put(existing, repo, entry))
    end
  end

  def handle_event("rm_repo_path", %{"repo" => repo}, socket) do
    write(socket, socket.assigns.workspace |> repo_paths_raw() |> Map.delete(repo))
  end

  defp write(socket, paths) do
    case patch_config(socket.assigns.workspace, %{"repo_paths" => paths}, ["repo_paths"]) do
      {:ok, ws} ->
        {:noreply,
         socket
         |> apply_workspace(ws)
         |> assign(:repo_path_error, nil)
         |> assign(:repo_paths, ws |> repo_paths() |> Enum.sort())}

      {:error, msg} ->
        {:noreply, assign(socket, :repo_path_error, msg)}
    end
  end

  # The raw `repo_paths` map — entries may be a bare path string or the
  # richer `%{"path" => ..., "target_branch" => ...}` shape set via the CLI.
  # Used as-is for writes so touching one entry can't clobber a sibling's
  # `target_branch`.
  defp repo_paths_raw(ws) do
    case cfg(ws, ["repo_paths"]) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  # `repo_paths_raw/1` flattened to a simple repo -> path string map for
  # display, same as `RepoConfig.find_path/2` elsewhere reads it. Entries that
  # don't resolve to a path string (malformed, e.g. `%{"target_branch" => .}`
  # with no `"path"`) are kept with a `nil` path rather than dropped, so they
  # still render (as "invalid") and can be removed from the dashboard.
  defp repo_paths(ws) do
    ws
    |> repo_paths_raw()
    |> Enum.map(fn {repo, entry} -> {repo, RepoConfig.repo_path_from_config(entry)} end)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={pane_class("repos", @section)}>
      <Data.data_table
        :if={@repo_paths != []}
        id="repo-paths"
        rows={@repo_paths}
        class="table-sm font-[family-name:var(--font-mono)] text-[11.5px]"
      >
        <:col :let={{repo, _path}} label="repo" width="110px">{repo}</:col>
        <:col :let={{_repo, path}} label="path">
          <span class="text-[var(--text-secondary)]">{path || "— (invalid entry)"}</span>
        </:col>
        <:col :let={{repo, _path}} label="worktree" width="84px">
          <span data-worktree-state={Map.get(@worktree_states, repo, "checking")}>
            <Data.status_chip
              status={Map.get(@worktree_states, repo, "checking")}
              class={[
                "badge-sm",
                Map.get(@worktree_states, repo, "checking") == "checking" && "animate-pulse"
              ]}
            />
          </span>
        </:col>
        <:col :let={{repo, _path}} label="" width="40px">
          <.remove_button
            label={"Remove repo path for #{repo}"}
            phx-click="rm_repo_path"
            phx-target={@myself}
            phx-value-repo={repo}
            data-confirm={"Remove the repo_paths entry for #{repo}?"}
          />
        </:col>
      </Data.data_table>

      <p
        :if={@worktree_error}
        id="repo-paths-worktree-error"
        role="alert"
        class="m-0 flex items-center gap-1.5 text-[11px] text-[var(--arb-fail-text)]"
      >
        <Core.icon name="hero-exclamation-triangle-micro" class="size-3.5 shrink-0" />
        Couldn't check worktree state: {@worktree_error}
      </p>

      <Feedback.empty_state
        :if={@repo_paths == []}
        icon="hero-folder-open"
        detail="repo_paths is empty"
      >
        No repo is registered yet — nothing can be dispatched.
      </Feedback.empty_state>

      <.rows>
        <.setting_row
          name="Add repo path"
          consequence="registers a checkout the dispatcher resolves a worker's working directory from"
        >
          <:below>
            <.form
              for={%{}}
              as={:repo_path}
              phx-submit="add_repo_path"
              phx-target={@myself}
              class="flex items-end gap-2"
            >
              <%!-- The flex sizing goes on wrappers, not on the inputs:
                   `Forms.input/1` with a label wraps the field in a
                   column-flex `<label>` and puts `class` on the inner span, so
                   a `flex-1` handed to the input would size a `w-full` child
                   instead of the flex item. --%>
              <div class="w-[140px] flex-none">
                <Forms.input
                  name="repo_path[repo]"
                  label="Repo"
                  value=""
                  size="sm"
                  placeholder="arbiter"
                  required
                />
              </div>
              <div class="min-w-0 flex-1">
                <Forms.input
                  name="repo_path[path]"
                  label="Path"
                  value=""
                  size="sm"
                  placeholder="~/dev/my-project"
                  required
                />
              </div>
              <Core.button type="submit" variant="primary" size="sm">Register</Core.button>
            </.form>
          </:below>
        </.setting_row>
      </.rows>

      <p :if={@repo_path_error} class="m-0 text-[11px] text-[var(--arb-fail-text)]">
        {@repo_path_error}
      </p>
    </div>
    """
  end
end
