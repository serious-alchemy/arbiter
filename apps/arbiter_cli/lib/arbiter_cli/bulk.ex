defmodule ArbiterCli.Bulk do
  @moduledoc """
  Shared plumbing for the bulk ticket verbs (`arb ticket promote|demote|rank
  id1 id2 ...`, bd-3cyf8j): collecting ids from argv and `--stdin`, and
  rendering the server's per-id result list
  (`{results: [{id, status: ok | refused | not_found, reason?, ticket?}],
  counts: {...}}`, the `Arbiter.Tasks.BulkResult` contract).

  One id on the command line and no `--stdin` stays the single-id call, with
  its single-id output. Anything else is a bulk call: one server round trip, one
  line per id, and a non-zero exit if any id was refused or not found.
  """

  alias ArbiterCli.Output

  @max_batch 200

  @doc """
  The ids a command was given: positional args plus, with `--stdin`, one id per
  stdin line (blank lines skipped).
  """
  @spec collect_ids([String.t()], keyword(), String.t()) :: [String.t()]
  def collect_ids(rest, opts, verb) do
    ids = rest ++ if(opts[:stdin], do: read_stdin(), else: [])

    ids
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] ->
        Output.die("#{verb} requires at least one ticket id")

      ids when length(ids) > @max_batch ->
        Output.die("too many ids: #{verb} takes at most #{@max_batch}, got #{length(ids)}")

      ids ->
        ids
    end
  end

  @doc "True when this invocation is a bulk call rather than the single-id form."
  @spec bulk?([String.t()], keyword()) :: boolean()
  def bulk?(rest, opts), do: opts[:stdin] == true or length(rest) > 1

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> String.split(data, "\n")
      _ -> []
    end
  end

  @doc """
  Print the response and exit non-zero if any id was refused or not found.
  `--json` prints the response as is; text is one line per id plus a summary.
  """
  @spec emit(map(), :json | :text) :: :ok
  def emit(%{"results" => results} = response, mode) do
    case mode do
      :json ->
        IO.puts(Jason.encode!(response))

      :text ->
        Enum.each(results, &IO.puts(line(&1)))
        IO.puts(summary(response["counts"] || %{}))
    end

    if Enum.all?(results, &(&1["status"] == "ok")), do: :ok, else: Output.halt(1)
  end

  @doc "One human line for a per-id result."
  @spec line(map()) :: String.t()
  def line(%{"status" => "ok", "id" => id} = result) do
    detail =
      case result["ticket"] do
        %{"state" => state} -> " (#{state})"
        _ -> ""
      end

    "ok         #{id}#{detail}"
  end

  def line(%{"status" => status, "id" => id} = result),
    do: "#{String.pad_trailing(status, 10)} #{id}: #{result["reason"]}"

  defp summary(counts) do
    "#{counts["ok"] || 0} ok, #{counts["refused"] || 0} refused, " <>
      "#{counts["not_found"] || 0} not found (#{counts["total"] || 0} total)"
  end
end
