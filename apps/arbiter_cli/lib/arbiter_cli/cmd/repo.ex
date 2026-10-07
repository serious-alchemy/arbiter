defmodule ArbiterCli.Cmd.Repo do
  @moduledoc """
  `arb repo <verb>` — the repo resource. A repo is a named repository
  checkout that workers operate on.

      arb repo list             registered repos with source + path
      arb repo show <name>      one repo's detail (active workers, worktrees)

  `list` reads from `GET /api/repos`; `show` reads from `GET /api/repos/:name`.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    case argv do
      ["list" | rest] -> list(rest)
      ["ls" | rest] -> list(rest)
      ["show" | rest] -> show(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("repo requires a subcommand", "verbs: list, show")
      [unknown | _] -> Output.die("unknown repo subcommand: #{unknown}", "verbs: list, show")
    end
  end

  defp list(argv) do
    {opts, _rest, _mode} = ArgParser.parse(argv, command: "arb repo", switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    case Client.get("/api/repos") do
      {:ok, %{"data" => repos}} -> emit_list(repos, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(repos, :json), do: IO.puts(Jason.encode!(%{data: repos}))

  defp emit_list([], :text), do: IO.puts("(no repos registered)")

  defp emit_list(repos, :text) do
    fmt = "~-24s ~-8s ~s~n"
    :io.format(fmt, ["NAME", "SOURCE", "PATH"])

    :io.format(fmt, [
      String.duplicate("-", 24),
      String.duplicate("-", 8),
      String.duplicate("-", 40)
    ])

    Enum.each(repos, fn repo ->
      :io.format(fmt, [
        repo["name"] || "",
        repo["source"] || "",
        repo["path"] || ""
      ])
    end)
  end

  defp show(argv) do
    {_opts, rest, mode} = ArgParser.parse(argv, command: "arb repo show", switches: [])

    name =
      case rest do
        [name] -> name
        [] -> Output.die("repo show requires a repo name: `arb repo show <name>`")
        _ -> Output.die("repo show takes exactly one argument: the repo name")
      end

    case Client.get("/api/repos/#{URI.encode(name)}") do
      {:ok, repo} when is_map(repo) ->
        emit_show(repo, mode)

      {:error, %Client.Error{status: 404}} when mode == :json ->
        IO.puts(Jason.encode!(%{"error" => "no repo named #{name}"}))
        Output.halt(1)

      {:error, %Client.Error{status: 404}} ->
        Output.die("no repo named #{inspect(name)} (try `arb repo list`)")

      {:error, err} ->
        Output.die(err)
    end
  end

  defp emit_show(repo, :json), do: IO.puts(Jason.encode!(repo))

  defp emit_show(repo, :text) do
    IO.puts("Repo:       #{repo["name"]}")
    IO.puts("Source:    #{repo["source"]}")
    IO.puts("Path:      #{repo["path"] || "(unknown)"}")
    IO.puts("Workers:   #{repo["workers"] || 0}")
    IO.puts("Worktrees: #{repo["worktrees"] || 0}")
  end
end
