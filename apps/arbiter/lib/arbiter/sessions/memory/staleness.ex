defmodule Arbiter.Sessions.Memory.Staleness do
  @moduledoc """
  Verifies memory candidates/files against the current checkout and quarantines
  them if they cite invalid `file:line` or modules.
  """

  alias Arbiter.Config.Paths

  @doc """
  Checks a memory file for staleness and quarantines it if invalid.
  Returns `:ok` or `{:error, :quarantined}`.
  """
  def check_memory(path, opts \\ []) do
    checkout = Keyword.get(opts, :primary_checkout, Paths.primary_checkout())
    frontmatter = parse_frontmatter(path)

    if frontmatter[:type] in ["project", "reference"] do
      body = read_body(path)

      if is_nil(checkout) or valid_citations?(body, checkout) do
        :ok
      else
        quarantine(path)
      end
    else
      :ok
    end
  end

  defp valid_citations?(body, checkout) do
    # Find file:line citations like lib/foo.ex:42
    citations = Regex.scan(~r/([\w\-\/]+\.\w+):(\d+)/, body)

    Enum.all?(citations, fn [_, file, line_str] ->
      line = String.to_integer(line_str)
      full_path = Path.join(checkout, file)

      if File.exists?(full_path) do
        case File.read(full_path) do
          {:ok, content} ->
            line_count = length(String.split(content, "\n"))
            line <= line_count

          _ ->
            false
        end
      else
        false
      end
    end)
  end

  defp quarantine(path) do
    root = Path.dirname(path)
    quarantine_dir = Path.join(root, "quarantined")
    File.mkdir_p!(quarantine_dir)
    dest = Path.join(quarantine_dir, Path.basename(path))
    File.rename!(path, dest)
    {:error, :quarantined}
  end

  @frontmatter_delim "---"

  defp parse_frontmatter(path) do
    case File.read(path) do
      {:ok, contents} -> do_parse_frontmatter(contents)
      {:error, _reason} -> %{}
    end
  end

  defp do_parse_frontmatter(contents) do
    with [@frontmatter_delim | rest] <- String.split(contents, "\n"),
         {block, _body} <- split_on_closing_delim(rest) do
      block
      |> Enum.map(&extract_key(&1, "type"))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> %{}
        [type | _] -> %{type: type}
      end
    else
      _ -> %{}
    end
  end

  defp split_on_closing_delim(lines) do
    case Enum.split_while(lines, &(&1 != @frontmatter_delim)) do
      {block, [@frontmatter_delim | body]} -> {block, body}
      _ -> {[], []}
    end
  end

  defp extract_key(line, key) do
    case Regex.run(~r/^\s*#{key}:\s*(\S+)\s*$/, line) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp read_body(path) do
    case File.read(path) do
      {:ok, contents} ->
        with [@frontmatter_delim | rest] <- String.split(contents, "\n"),
             {_block, body} <- split_on_closing_delim(rest) do
          Enum.join(body, "\n")
        else
          _ -> contents
        end

      _ ->
        ""
    end
  end
end
