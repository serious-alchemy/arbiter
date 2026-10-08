defmodule ArbiterWeb.CoreComponents.NodeBadge do
  @moduledoc """
  Where a worker run executes (bd-1b4k9r).

  The one place the dashboard renders a run's node, from the `node_name` every
  run view carries (`Arbiter.Workers.RunNode`; `nil` is the primary).

    * `node_badge/1` — a small icon for tight spots (the board card, next to the
      provider logo). Renders only for a remote run, so a local card looks as it
      always did; the tooltip names the node.
    * `run_where/1` — text, for lists and detail pages. The node's name (or
      `local`) where there is room, `remote`/`local` with `compact`.
  """
  use Phoenix.Component

  alias ArbiterWeb.CoreComponents, as: Core

  attr :node_name, :string, default: nil, doc: "the node's name; nil for a local run"
  attr :class, :any, default: "size-3.5 text-[var(--text-label)]"
  attr :rest, :global

  def node_badge(%{node_name: name} = assigns) when is_binary(name) do
    ~H"""
    <span
      data-node-badge={@node_name}
      title={"Runs on node #{@node_name}"}
      aria-label={"Remote run on node #{@node_name}"}
      class="inline-flex items-center"
      {@rest}
    >
      <Core.icon name="hero-server-stack-micro" class={@class} />
    </span>
    """
  end

  def node_badge(assigns), do: ~H""

  attr :node_name, :string, default: nil, doc: "the node's name; nil for a local run"
  attr :compact, :boolean, default: false, doc: "show only remote/local, not the node's name"
  attr :class, :any, default: nil
  attr :rest, :global

  def run_where(assigns) do
    assigns = assign(assigns, :remote?, is_binary(assigns.node_name))

    ~H"""
    <span
      data-run-node={if(@remote?, do: @node_name, else: "local")}
      data-remote={to_string(@remote?)}
      title={if(@remote?, do: "Runs on node #{@node_name}", else: "Runs on the primary")}
      class={["font-[family-name:var(--font-mono)]", @class]}
      {@rest}
    >
      <%= cond do %>
        <% @remote? and @compact -> %>
          remote
        <% @remote? -> %>
          {@node_name}
        <% true -> %>
          local
      <% end %>
    </span>
    """
  end
end
