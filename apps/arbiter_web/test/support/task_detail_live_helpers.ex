defmodule ArbiterWeb.TaskDetailLiveHelpers do
  @moduledoc """
  Mounting `/tasks/:id` in a LiveView test now that the page loads async
  (bd-dhghus): the connected mount starts the header load (task, workspace,
  worker), and the header's arrival starts the per-panel loads. So a single
  `render_async/2` only settles the first stage — `render_task/1` waits for
  both.
  """

  import Phoenix.LiveViewTest

  # Generous: a loaded suite can outrun render_async's 100 ms default.
  @async_timeout 5_000

  @doc """
  `live/2` against a task detail path, returning the fully loaded HTML in
  place of the loading-state first render.
  """
  defmacro live_task(conn, path) do
    quote do
      case live(unquote(conn), unquote(path)) do
        {:ok, view, _html} -> {:ok, view, ArbiterWeb.TaskDetailLiveHelpers.render_task(view)}
        other -> other
      end
    end
  end

  @doc "Wait out the header load, then the panel loads it started; return the HTML."
  def render_task(view) do
    render_async(view, @async_timeout)
    render_async(view, @async_timeout)
  end
end
