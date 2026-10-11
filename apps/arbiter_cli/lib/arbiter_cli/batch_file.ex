defmodule ArbiterCli.BatchFile do
  @moduledoc """
  Reading the documents the bulk-filing verbs take: `arb ticket create
  --from-file <path|->` / `--stdin` (a ticket graph, JSON or YAML) and
  `arb dep add --stdin` (a list of edges, JSON or `<from> <type> <to>` lines).

  A path of `-` (or `--stdin`) reads standard input. Parsing is JSON first, then
  YAML (every JSON document is also YAML, so a `.json` file with a trailing comma
  is reported as a YAML error, not silently accepted). Every failure dies with a
  message naming the source — nothing has been sent to the server yet.
  """

  alias ArbiterCli.Output

  @doc "Read the whole source: a file path, or `-` for stdin."
  @spec read!(String.t()) :: String.t()
  def read!("-") do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) and data != "" -> data
      _ -> Output.die("nothing on stdin")
    end
  end

  def read!(path) do
    case File.read(path) do
      {:ok, data} -> data
      {:error, reason} -> Output.die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc """
  Parse a ticket-graph document into `{tickets, doc_opts}`.

  Accepts a bare list of tickets, or an object `{tickets: [...], promote?, force?,
  acceptance_waived?}`; `doc_opts` carries the object's `promote` / `force` /
  `acceptance_waived` so a file can say "promote after filing" itself.
  """
  @spec tickets!(String.t(), String.t()) :: {[map()], map()}
  def tickets!(text, label) do
    case decode!(text, label) do
      list when is_list(list) ->
        {check_tickets!(list, label), %{}}

      %{"tickets" => list} = doc when is_list(list) ->
        {check_tickets!(list, label), Map.take(doc, ~w(promote force acceptance_waived))}

      _ ->
        Output.die("#{label}: expected a list of tickets, or an object with a `tickets` list")
    end
  end

  defp check_tickets!([], label), do: Output.die("#{label}: no tickets in the document")

  defp check_tickets!(list, label) do
    case Enum.find_index(list, &(not is_map(&1))) do
      nil -> list
      i -> Output.die("#{label}: tickets[#{i}] is not an object")
    end
  end

  @doc """
  Parse a bulk-edge document into a list of `%{"from", "to", "type"}` maps.

  Either JSON (`[{"from": .., "to": .., "type": ..}, ..]` or `{"edges": [..]}`) or
  plain lines, one edge each, in the positional order of `arb dep add`:
  `<from> <type> <to>` (blank lines and `#` comments skipped).
  """
  @spec edges!(String.t(), String.t()) :: [map()]
  def edges!(text, label) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        Output.die("#{label}: no edges")

      String.starts_with?(trimmed, ["[", "{"]) ->
        json_edges!(trimmed, label)

      true ->
        line_edges!(text, label)
    end
  end

  defp json_edges!(text, label) do
    case decode!(text, label) do
      list when is_list(list) and list != [] -> list
      %{"edges" => [_ | _] = list} -> list
      _ -> Output.die("#{label}: expected a non-empty list of edges, or an object with `edges`")
    end
  end

  defp line_edges!(text, label) do
    edges =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, n} -> {String.trim(line), n} end)
      |> Enum.reject(fn {line, _n} -> line == "" or String.starts_with?(line, "#") end)
      |> Enum.map(fn {line, n} ->
        case String.split(line) do
          [from, type, to] ->
            %{"from" => from, "type" => type, "to" => to}

          _ ->
            Output.die("#{label}: line #{n}: expected `<from> <type> <to>`, got #{inspect(line)}")
        end
      end)

    if edges == [], do: Output.die("#{label}: no edges"), else: edges
  end

  defp decode!(text, label) do
    case Jason.decode(text) do
      {:ok, value} ->
        value

      {:error, json_error} ->
        case yaml(text) do
          {:ok, value} ->
            value

          {:error, reason} ->
            Output.die(
              "#{label}: could not parse as JSON (#{Exception.message(json_error)}) " <>
                "or YAML (#{reason})"
            )
        end
    end
  end

  defp yaml(text) do
    case YamlElixir.read_from_string(text) do
      {:ok, value} -> {:ok, value}
      {:error, %{__exception__: true} = e} -> {:error, Exception.message(e)}
      {:error, other} -> {:error, inspect(other)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end
end
