defmodule Arbiter.Sessions.Memory.Staleness do
  @moduledoc """
  Verifies memory candidates/files against the current checkout and quarantines
  them if they cite invalid `file:line` or modules.
  """

  

  @doc """
  Checks a memory file for staleness against its workspace checkout.
  Returns `:ok` or `{:error, :stale}`. Does NOT quarantine.
  """
  def check_memory(path, opts \\ []) do
    frontmatter = parse_frontmatter(path)

    # We only check project memories because only project memories are bound to a workspace checkout.
    if frontmatter[:type] == "project" do
      case workspace_checkout(frontmatter[:workspace_id], opts) do
        nil -> :ok
        checkout ->
          body = read_body(path)
          verified_sha = frontmatter[:verified_sha]
          
          # We only need to check if we don't have a verified_sha or if the current HEAD differs
          head_sha = get_head_sha(checkout)
          if head_sha == nil or verified_sha == nil or verified_sha != head_sha do
            if valid_citations?(body, checkout) do
              :ok
            else
              {:error, :stale}
            end
          else
            :ok
          end
      end
    else
      :ok
    end
  end

  @doc """
  Quarantines a memory file, recording the reason and SHA.
  """
  def quarantine(path, reason, sha \\ nil) do
    root = Path.dirname(path)
    quarantine_dir = Path.join(root, "quarantined")
    File.mkdir_p!(quarantine_dir)
    dest = Path.join(quarantine_dir, Path.basename(path))
    
    # Prepend quarantine reason to the file before moving it
    body = read_body(path)
    fm = parse_frontmatter(path)
    fm_lines = Enum.map(fm, fn {k, v} -> "#{k}: #{v}" end)
    fm_lines = if sha, do: fm_lines ++ ["quarantine_sha: #{sha}"], else: fm_lines
    fm_lines = fm_lines ++ ["quarantine_reason: #{reason}"]
    
    new_content = "---\n" <> Enum.join(fm_lines, "\n") <> "\n---\n\n" <> body
    File.write!(path, new_content)
    
    File.rename!(path, dest)
    {:error, :quarantined}
  end

  defp get_head_sha(checkout) do
    case System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  def workspace_checkout(workspace_id, opts) do
    if checkout = Keyword.get(opts, :primary_checkout) do
      checkout
    else
      if workspace_id do
        case Ash.get(Arbiter.Tasks.Workspace, workspace_id) do
          {:ok, ws} ->
            paths = ws.config["repo_paths"] || %{}
            case Enum.to_list(paths) do
              [{_, entry} | _] -> Arbiter.Tasks.RepoConfig.repo_path_from_config(entry)
              _ -> nil
            end
          _ -> nil
        end
      else
        nil
      end
    end
  end

  def valid_citations?(body, checkout) do
    valid_file_citations?(body, checkout) and valid_module_citations?(body, checkout)
  end

  defp valid_file_citations?(body, checkout) do
    citations = Regex.scan(~r/(?:^|[\s"'\(`])((?:[\w\-\.]+\/)+[\w\-\.]+\.\w+):(\d+)/, body)

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

  defp valid_module_citations?(body, checkout) do
    citations = Regex.scan(~r/(?:^|[\s"'\(`])([A-Z][a-zA-Z0-9_]*(?:\.[A-Z][a-zA-Z0-9_]*)+)/, body)

    Enum.all?(citations, fn [_, module_name] ->
      # Use git grep to find defmodule Foo.Bar
      case System.cmd("git", ["-C", checkout, "grep", "-q", "defmodule #{module_name}"]) do
        {_, 0} -> true
        _ -> false
      end
    end)
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
      Enum.reduce(block, %{}, fn line, acc ->
        case Regex.run(~r/^\s*([\w_]+):\s*(.+?)\s*$/, line) do
          [_, key, value] -> Map.put(acc, String.to_atom(key), value)
          nil -> acc
        end
      end)
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

  defp read_body(path) do
    case File.read(path) do
      {:ok, contents} ->
        with [@frontmatter_delim | rest] <- String.split(contents, "\n"),
             {_block, body} <- split_on_closing_delim(rest) do
          Enum.join(body, "\n") |> String.trim_leading()
        else
          _ -> contents
        end

      _ ->
        ""
    end
  end

  @doc """
  Explicitly sweeps all memories in the memory root, quarantining any that are stale.
  """
  def sweep(memory_root, opts \\ []) do
    case File.ls(memory_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.each(fn file ->
          path = Path.join(memory_root, file)
          case check_memory(path, opts) do
            {:error, :stale} -> quarantine(path, "Stale citations found during sweep")
            _ -> :ok
          end
        end)
      _ -> :ok
    end
  end
end
