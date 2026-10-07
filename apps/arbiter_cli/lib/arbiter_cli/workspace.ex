defmodule ArbiterCli.Workspace do
  @moduledoc """
  Resolves the active workspace.

  Lookup order when `ARB_WORKSPACE` is unset:
    1. Workspace literally named `"default"`
    2. The sole workspace, if exactly one exists (an install that never had —
       or has since deleted — a workspace named `"default"` should still just
       work when there's no ambiguity about which workspace is "active")

  When `ARB_WORKSPACE` (or `--workspace`) is set, it is matched exactly by
  name or id and no fallback applies — an explicit selector that doesn't
  match is always an error.

  Returns `{:ok, workspace_map}` or `{:error, reason_string}`.
  """

  alias ArbiterCli.Client

  @doc """
  Pull a `--workspace <name>` / `--workspace=<name>` (or `-w`) flag out of an
  arg list, returning `{name_or_nil, remaining_argv}`.

  Workspace selection is a cross-cutting concern resolved centrally via
  `ARB_WORKSPACE` (see `resolve/0`), but the individual `arb ticket *`
  subcommands each parse their own switches and would otherwise swallow a
  `--workspace` flag as an unknown boolean. Extracting it here — before the
  subcommand's own `OptionParser` runs — lets the flag override the active
  workspace exactly as the env var does, for every subcommand uniformly.

  The last occurrence wins. The returned name is applied by the caller via
  `System.put_env("ARB_WORKSPACE", name)`.
  """
  @spec take_flag([String.t()]) :: {String.t() | nil, [String.t()]}
  def take_flag(argv) when is_list(argv) do
    case extract_flag(argv) do
      {_flag, value, rest} -> {value, rest}
    end
  end

  @doc """
  Like `take_flag/1`, but also returns the exact flag switch that was supplied
  (`"-w"`, `"--workspace"`, `"-w=..."`, `"--workspace=..."`, or `nil`).
  """
  @spec extract_flag([String.t()]) :: {String.t() | nil, String.t() | nil, [String.t()]}
  def extract_flag(argv) when is_list(argv), do: do_extract_flag(argv, nil, nil, [])

  defp do_extract_flag([], flag, name, kept), do: {flag, name, Enum.reverse(kept)}

  defp do_extract_flag([flag, value | rest], _flag, _name, kept)
       when flag in ["--workspace", "-w"],
       do: do_extract_flag(rest, flag, value, kept)

  defp do_extract_flag([flag], _flag, name, kept) when flag in ["--workspace", "-w"],
    # Dangling flag with no value — drop it; keep flag for reporting.
    do: do_extract_flag([], flag, name, kept)

  defp do_extract_flag(["--workspace=" <> value = full | rest], _flag, _name, kept),
    do: do_extract_flag(rest, full, value, kept)

  defp do_extract_flag(["-w=" <> value = full | rest], _flag, _name, kept),
    do: do_extract_flag(rest, full, value, kept)

  defp do_extract_flag([arg | rest], flag, name, kept),
    do: do_extract_flag(rest, flag, name, [arg | kept])

  @spec resolve(String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def resolve(target \\ nil) do
    target = target || System.get_env("ARB_WORKSPACE")

    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} ->
        resolve_from_list(list, target)

      {:error, %Client.Error{} = err} ->
        {:error, "could not load workspaces: #{err.message}"}
    end
  end

  # Explicit selector (env var or --workspace flag): must match exactly, no
  # fallback. Getting this wrong silently would route commands at the wrong
  # workspace.
  defp resolve_from_list(list, target) when is_binary(target) do
    case Enum.find(list, &(&1["name"] == target or &1["id"] == target)) do
      nil ->
        {:error,
         "no workspace named #{inspect(target)}. " <>
           "Set ARB_WORKSPACE or create one with `arb workspace create`."}

      ws ->
        {:ok, ws}
    end
  end

  # No explicit selector: prefer a workspace literally named "default"; when
  # there isn't one but exactly one workspace exists, resolve to it — there's
  # no ambiguity to warn about. Only error when the choice is genuinely
  # ambiguous (multiple workspaces, none named "default").
  defp resolve_from_list([], nil) do
    {:error, "no workspaces found. Create one with `arb workspace create`."}
  end

  defp resolve_from_list(list, nil) do
    case Enum.find(list, &(&1["name"] == "default")) do
      nil ->
        case list do
          [only] ->
            {:ok, only}

          _ ->
            {:error,
             "no workspace named \"default\" and #{length(list)} workspaces exist — " <>
               "set ARB_WORKSPACE to pick one."}
        end

      ws ->
        {:ok, ws}
    end
  end

  @doc "Convenience: resolve and return just the id, or halt with a friendly error."
  @spec id_or_halt(String.t() | nil) :: String.t()
  def id_or_halt(target \\ nil) do
    case resolve(target) do
      {:ok, ws} -> ws["id"]
      {:error, msg} -> ArbiterCli.Output.die(msg)
    end
  end
end
