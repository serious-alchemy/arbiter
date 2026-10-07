defmodule ArbiterCli.Cmd.Workspace.Env do
  @moduledoc """
  `arb workspace env ls|set|rm` — user-defined env vars injected into every
  worker's subprocess (`Arbiter.Worker.WorkerEnv`). Values are write-only: `ls`
  shows names and secret flags, never a value, and revealing a value stays in
  the browser.

  `set <NAME>` takes the value from `--file PATH`, from stdin (`set <NAME> -`),
  or — warning on stderr, since argv is visible host-wide — as `set <NAME>
  <value>`. `--secret` encrypts-and-redacts the var in worker output;
  `--no-secret` clears the flag. With a flag and **no** value, `set` flips the
  flag of an existing var without touching its value.
  """

  alias ArbiterCli.ArgParser
  alias ArbiterCli.{Client, Output, SecretInput}
  alias ArbiterCli.Cmd.Workspace.Resolver

  @name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @alt "`set <NAME> --file <path>` or `set <NAME> -` (stdin)"

  @spec run([String.t()], keyword()) :: :ok | no_return()
  def run(argv, opts) do
    {parsed, rest, mode} =
      ArgParser.parse(argv,
        command: "arb workspace env",
        switches: Keyword.fetch!(opts, :switches) ++ [file: :string, secret: :boolean]
      )

    dispatch(rest, parsed, mode)
  end

  defp dispatch(["ls"], parsed, mode), do: ls(parsed[:workspace], mode)

  defp dispatch(["ls" | _], _parsed, _mode),
    do: Output.die("workspace env ls takes no positional arguments")

  defp dispatch(["set", name], parsed, mode),
    do: set(parsed[:workspace], name, value_from_flags(parsed), parsed[:secret], mode)

  defp dispatch(["set", name, "-"], parsed, mode),
    do: set(parsed[:workspace], name, {:value, SecretInput.from_stdin!()}, parsed[:secret], mode)

  defp dispatch(["set", name | vrest], parsed, mode) when vrest != [] do
    SecretInput.warn_argv(@alt)
    set(parsed[:workspace], name, {:value, Enum.join(vrest, " ")}, parsed[:secret], mode)
  end

  defp dispatch(["set" | _], _parsed, _mode), do: Output.die("workspace env set requires <NAME>")
  defp dispatch(["rm", name], parsed, mode), do: rm(parsed[:workspace], name, mode)

  defp dispatch(["rm" | _], _parsed, _mode),
    do: Output.die("workspace env rm requires exactly one <NAME>")

  defp dispatch([], _parsed, _mode),
    do: Output.die("workspace env requires a subcommand", "verbs: ls, set, rm")

  defp dispatch([unknown | _], _parsed, _mode),
    do: Output.die("unknown workspace env subcommand: #{unknown}", "verbs: ls, set, rm")

  defp value_from_flags(parsed) do
    case parsed[:file] do
      path when is_binary(path) -> {:value, SecretInput.from_file!(path, "--file")}
      nil -> :none
    end
  end

  defp ls(workspace_opt, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)
    vars = ws["worker_env"] || []

    case mode do
      :json -> Output.emit_json(%{"worker_env" => vars})
      :text -> print(vars)
    end
  end

  defp set(workspace_opt, name, value, secret, mode) do
    unless Regex.match?(@name_re, name) do
      Output.die(
        "workspace env set: invalid env var name #{inspect(name)}",
        "must match [A-Za-z_][A-Za-z0-9_]*"
      )
    end

    patch =
      case {value, secret} do
        {:none, nil} ->
          Output.die(
            "workspace env set requires a value (<value>, -, or --file <path>) " <>
              "or --secret / --no-secret to flip the flag of an existing var"
          )

        {:none, flag} ->
          %{"secret" => flag}

        {{:value, ""}, _} ->
          Output.die("workspace env set: the value is empty")

        {{:value, v}, nil} ->
          %{"value" => v}

        {{:value, v}, flag} ->
          %{"value" => v, "secret" => flag}
      end

    patch_env(Resolver.resolve_workspace!(workspace_opt), %{name => patch}, mode)
  end

  defp rm(workspace_opt, name, mode) do
    ws = Resolver.resolve_workspace!(workspace_opt)

    unless Enum.any?(ws["worker_env"] || [], &(&1["name"] == name)) do
      Output.die("workspace env rm: no worker env var named #{inspect(name)}")
    end

    # A null value tells the server's merge-patch to remove the var.
    patch_env(ws, %{name => nil}, mode)
  end

  # The response is the names-only workspace record — a value is never echoed.
  defp patch_env(%{"id" => id}, patch, mode) do
    case Client.patch("/api/workspaces/" <> id, %{"worker_env" => patch}) do
      {:ok, updated} ->
        vars = updated["worker_env"] || []

        case mode do
          :json ->
            Output.emit_json(%{"worker_env" => vars})

          :text ->
            IO.puts("ok — worker env: #{if vars == [], do: "(none)", else: names(vars)}")
        end

      {:error, err} ->
        Output.die(err)
    end
  end

  defp names(vars), do: Enum.map_join(vars, ", ", &label/1)

  defp label(%{"name" => name, "secret" => true}), do: name <> " (secret)"
  defp label(%{"name" => name}), do: name

  defp print([]), do: IO.puts("(no worker env vars)")

  defp print(vars) do
    IO.puts("Worker env vars (#{length(vars)}):")
    Enum.each(vars, &IO.puts("  #{label(&1)}"))
  end
end
