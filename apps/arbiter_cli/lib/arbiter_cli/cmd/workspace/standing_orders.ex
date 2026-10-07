defmodule ArbiterCli.Cmd.Workspace.StandingOrders do
  @moduledoc """
  `arb workspace standing-order ls|add|rm` — workspace-global or
  repo-scoped standing orders (`config.standing_orders` /
  `repo_paths.<repo>.standing_orders`).
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Output}
  alias ArbiterCli.Cmd.Workspace.Resolver

  @spec run([String.t()], keyword()) :: :ok | no_return()
  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv, opts) do
    {parsed, rest, mode} =
      ArgParser.parse(argv,
        command: "arb workspace standing-order",
        switches: Keyword.fetch!(opts, :switches)
      )

    workspace_opt = parsed[:workspace]
    # --repo is canonical; --rig is a deprecated alias kept for existing
    # scripts/muscle-memory (bd-1aw9dl). --repo wins if both are given.
    repo_opt = parsed[:repo] || parsed[:rig]

    case rest do
      ["ls"] ->
        ls(workspace_opt, repo_opt, mode)

      ["ls" | _] ->
        Output.die("workspace standing-order ls takes no positional arguments")

      ["add" | text] when text != [] ->
        add(workspace_opt, repo_opt, Enum.join(text, " "), mode)

      ["add" | _] ->
        Output.die("workspace standing-order add requires <text>")

      ["rm", target] ->
        rm(workspace_opt, repo_opt, target, mode)

      ["rm" | rest_args] when rest_args != [] ->
        # Allow an unquoted multi-word text match as a convenience.
        rm(workspace_opt, repo_opt, Enum.join(rest_args, " "), mode)

      ["rm" | _] ->
        Output.die("workspace standing-order rm requires an <index|text>")

      [] ->
        Output.die("workspace standing-order requires a subcommand", "verbs: ls, add, rm")

      [unknown | _] ->
        Output.die(
          "unknown workspace standing-order subcommand: #{unknown}",
          "verbs: ls, add, rm"
        )
    end
  end

  defp ls(workspace_opt, repo_opt, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    orders = current_standing_orders(ws, repo_opt)

    case mode do
      :json ->
        Output.emit_json(orders_json(orders, repo_opt))

      :text ->
        if orders == [] do
          IO.puts("(no standing orders#{repo_label(repo_opt)})")
        else
          IO.puts("Standing orders#{repo_label(repo_opt)} (#{length(orders)}):")

          orders
          |> Enum.with_index(1)
          |> Enum.each(fn {o, i} -> IO.puts("  #{i}. #{order_text(o)}") end)
        end
    end
  end

  # `add` / `rm` are server-side single-entry operations
  # (`POST /api/workspaces/:id/standing_orders[/remove]`): the server appends to
  # / removes from the list it has just re-read under a lock, so two callers
  # editing at once both keep their change. The CLI no longer reads the list and
  # writes it back.
  defp add(workspace_opt, repo_opt, text, mode) do
    text = String.trim(text)
    if text == "", do: Output.die("workspace standing-order add: text must not be empty")

    ws = Resolver.resolve_workspace!(workspace_opt)
    body = maybe_repo(%{"text" => text}, repo_opt)
    write(ws, "/standing_orders", body, repo_opt, mode)
  end

  defp rm(workspace_opt, repo_opt, target, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    # A 1-based index or the exact text; the server tells them apart.
    body = maybe_repo(%{"target" => target}, repo_opt)
    write(ws, "/standing_orders/remove", body, repo_opt, mode)
  end

  defp maybe_repo(body, nil), do: body
  defp maybe_repo(body, repo), do: Map.put(body, "repo", repo)

  defp write(%{} = ws, suffix, body, repo, mode) do
    case Client.post("/api/workspaces/" <> ws["id"] <> suffix, body) do
      {:ok, %{"standing_orders" => new_orders}} ->
        case mode do
          :json ->
            Output.emit_json(orders_json(new_orders, repo))

          :text ->
            IO.puts("ok — #{length(new_orders)} standing order(s)")

            new_orders
            |> Enum.with_index(1)
            |> Enum.each(fn {o, i} -> IO.puts("  #{i}. #{order_text(o)}") end)
        end

      {:ok, _} ->
        Output.die("unexpected response from the server")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp orders_json(orders, nil), do: %{"standing_orders" => orders}

  # "repo" is canonical; "rig" is dual-emitted alongside it as a deprecated
  # legacy key so existing consumers keep working (bd-1aw9dl).
  defp orders_json(orders, repo),
    do: %{"standing_orders" => orders, "repo" => repo, "rig" => repo}

  defp repo_label(nil), do: ""
  defp repo_label(repo), do: " for repo #{repo}"

  defp current_standing_orders(ws, nil) do
    case get_in(ws, ["config", "standing_orders"]) do
      orders when is_list(orders) -> orders
      _ -> []
    end
  end

  defp current_standing_orders(ws, repo) do
    case Resolver.resolve_repo(ws, repo) do
      {_key, _entry_key, %{"standing_orders" => orders}} when is_list(orders) -> orders
      _ -> []
    end
  end

  # A standing order is either a short imperative string or a {title, detail}
  # object; render either to a single human-readable line (matches `arb prime`).
  defp order_text(order) when is_binary(order), do: order

  defp order_text(%{"title" => title} = order) do
    case order["detail"] do
      d when is_binary(d) and d != "" -> "#{title} — #{d}"
      _ -> title
    end
  end

  defp order_text(order), do: inspect(order)
end
