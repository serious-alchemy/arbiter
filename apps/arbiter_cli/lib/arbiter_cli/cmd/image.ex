defmodule ArbiterCli.Cmd.Image do
  @moduledoc """
  Worker images for the podman sandbox backend (bd-9r5jdt):

      arb image list [--json]
                                  Arbiter's local dev images (one shared base
                                  plus a toolchain layer per distinct Erlang /
                                  Elixir / Node tuple) and the base-image
                                  digest pins
      arb image build <repo> [--workspace W] [--json]
                                  plan <repo>'s image from its DEFAULT BRANCH
                                  and build whatever is missing (single-flight;
                                  returns once the tag exists)
      arb image refresh [--json]  re-resolve every base-image pin now (the
                                  weekly refresh does this on its own) and prune
      arb image prune [--json]    remove stale tags (the newest two per image
                                  name stay)

  Tags are content hashes (`localhost/arbiter-dev/<name>:<hash12>`): a changed
  `.tool-versions`, `.arbiter/Containerfile` or base digest is a new tag, a
  changed `mix.lock` is not. The definition is `.arbiter/Containerfile` (or a
  default generated from `.tool-versions`) as committed on the default branch;
  a worker's branch is never built.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  # A cold build installs a toolchain over the network.
  @build_timeout_ms 25 * 60_000

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv, command: "arb image", switches: [workspace: :string])

      case rest do
        ["list" | _] -> list(mode)
        ["build" | args] -> build(args, opts, mode)
        ["refresh" | _] -> post("/api/images/refresh", %{}, mode, &print_refresh/1)
        ["prune" | _] -> post("/api/images/prune", %{}, mode, &print_prune/1)
        _ -> unknown()
      end
    end
  end

  @spec unknown() :: no_return()
  defp unknown do
    IO.puts(:stderr, "arb: unknown image subcommand")
    IO.puts(:stderr, "Run `arb image --help` for usage.")
    Output.halt(2)
  end

  defp list(mode) do
    case Client.get("/api/images") do
      {:ok, body} -> emit(body, mode, &print_list/1)
      {:error, %Client.Error{} = err} -> Output.die(err)
    end
  end

  defp build(args, opts, mode) do
    repo =
      case List.first(args) do
        nil -> Output.die("arb image build needs a repo", "Run `arb repo list` for the names.")
        repo -> repo
      end

    body =
      case opts[:workspace] do
        nil -> %{repo: repo}
        workspace -> %{repo: repo, workspace: workspace}
      end

    case Client.post("/api/images/build", body, receive_timeout: @build_timeout_ms) do
      {:ok, resp} -> emit(resp, mode, &print_build/1)
      {:error, %Client.Error{} = err} -> Output.die(err)
    end
  end

  defp post(path, body, mode, printer) do
    case Client.post(path, body, receive_timeout: @build_timeout_ms) do
      {:ok, resp} -> emit(resp, mode, printer)
      {:error, %Client.Error{} = err} -> Output.die(err)
    end
  end

  defp emit(body, :json, _printer), do: IO.puts(Jason.encode!(body))
  defp emit(body, _mode, printer), do: printer.(body)

  # -- text output -------------------------------------------------------------

  defp print_list(body) do
    unless body["podman"],
      do: IO.puts("podman is not installed on this host (`arb server doctor`).")

    case body["images"] || [] do
      [] ->
        IO.puts("No worker images built yet. Build one with `arb image build <repo>`.")

      images ->
        IO.puts("WORKER IMAGES")
        :io.format("  ~-34s ~-8s ~-14s ~8s  ~s~n", ["NAME", "KIND", "HASH", "SIZE", "CREATED"])

        Enum.each(images, fn i ->
          :io.format("  ~-34s ~-8s ~-14s ~8s  ~s~n", [
            i["name"],
            i["kind"],
            i["hash"],
            megabytes(i["size"]),
            created(i["created"])
          ])
        end)
    end

    print_pins(body["pins"] || [], body)
  end

  defp print_pins([], _body), do: :ok

  defp print_pins(pins, body) do
    IO.puts("")
    IO.puts("BASE IMAGE PINS (digest-pinned; the weekly refresh moves them)")

    Enum.each(pins, fn p ->
      IO.puts("  #{p["ref"]}")
      IO.puts("      #{p["digest"]}  (resolved #{p["resolved_at"]})")
    end)

    refreshed = body["refreshed_at"] || "never"
    due = if body["refresh_due"], do: "  — refresh is DUE (`arb image refresh`)", else: ""
    IO.puts("  last refresh: #{refreshed}#{due}")
  end

  defp print_build(resp) do
    IO.puts(resp["tag"])

    case resp["built"] || [] do
      [] -> IO.puts("  already built")
      built -> IO.puts("  built #{length(built)} layer(s): #{Enum.join(built, ", ")}")
    end

    IO.puts("  from #{resp["ref"]} (#{resp["source"]} Containerfile)")
  end

  defp print_refresh(resp) do
    case resp["changed"] || [] do
      [] ->
        IO.puts("No base image digest moved.")

      changed ->
        IO.puts("Base images that moved (images on them rebuild on next use):")
        Enum.each(changed, &IO.puts("  #{&1["ref"]}\n      #{&1["from"]} -> #{&1["to"]}"))
    end

    Enum.each(resp["failed"] || [], &IO.puts("  could not refresh #{&1["ref"]}: #{&1["reason"]}"))
    print_prune(resp["pruned"] || %{})
  end

  defp print_prune(resp) do
    removed = resp["removed"] || []
    IO.puts("Removed #{length(removed)} stale image(s).")
    Enum.each(removed, &IO.puts("  #{&1}"))
    Enum.each(resp["failed"] || [], &IO.puts("  kept #{&1["tag"]} (#{&1["reason"]})"))
  end

  defp megabytes(bytes) when is_integer(bytes), do: "#{div(bytes, 1_000_000)} MB"
  defp megabytes(_), do: "?"

  defp created(unix) when is_integer(unix) and unix > 0,
    do: unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp created(_), do: "?"
end
