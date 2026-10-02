defmodule Arbiter.Sessions.Memory.Promotion do
  @moduledoc """
  Promotion queue for candidate memories written by sessions.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions.Memory.Staleness

  @doc """
  Lists all candidate memories across all sessions.
  """
  def list_candidates do
    sessions_root = Paths.sessions_root()

    case File.ls(sessions_root) do
      {:ok, sessions} ->
        Enum.flat_map(sessions, fn session_id ->
          candidate_dir = Path.join([sessions_root, session_id, "memory", "candidates"])

          case File.ls(candidate_dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".md"))
              |> Enum.map(fn filename ->
                %{
                  session_id: session_id,
                  filename: filename,
                  path: Path.join(candidate_dir, filename)
                }
              end)

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp validate_candidate_path(path) do
    # Check if the path is actually in a session's candidates dir
    sessions_root = Paths.sessions_root()
    expanded_path = Path.expand(path)

    if String.contains?(expanded_path, "..") do
      {:error, :invalid_path}
    else
      # Check if it starts with sessions_root and contains /memory/candidates/
      if String.starts_with?(expanded_path, Path.expand(sessions_root)) and
           String.contains?(expanded_path, "/memory/candidates/") do
        {:ok, expanded_path}
      else
        {:error, :invalid_path}
      end
    end
  end

  @doc """
  Promotes a candidate memory to the shared layer.
  """
  def promote(path, opts \\ []) do
    with {:ok, safe_path} <- validate_candidate_path(path) do
      memory_root = Keyword.get(opts, :memory_root, Paths.memory_root())
      dest = Path.join(memory_root, Path.basename(safe_path))

      overwrite? = Keyword.get(opts, :overwrite, false)

      if File.exists?(dest) and not overwrite? do
        {:error, :exists}
      else
        File.mkdir_p!(memory_root)

        # Run citation checks against workspace checkout's HEAD
        case Staleness.check_memory(safe_path, opts) do
          {:error, :stale} ->
            {:error, :stale}

          :ok ->
            # Actually we need to set verified_sha if it's a project memory.
            # check_memory just validates citations. We need to parse and write verified_sha.
            fm = parse_frontmatter(safe_path)

            if fm[:type] == "project" do
              checkout = Staleness.workspace_checkout(fm[:workspace_id], opts)
              head_sha = get_head_sha(checkout)

              if head_sha do
                prepend_verified_sha(safe_path, head_sha)
              end
            end

            case File.rename(safe_path, dest) do
              :ok ->
                :ok

              {:error, :exdev} ->
                # Cross-device fallback
                case File.cp(safe_path, dest) do
                  :ok ->
                    File.rm(safe_path)
                    :ok

                  {:error, reason} ->
                    {:error, {:system_error, reason}}
                end

              {:error, reason} ->
                {:error, {:system_error, reason}}
            end
        end
      end
    end
  end

  defp prepend_verified_sha(path, sha) do
    content = File.read!(path)
    [frontmatter_delim | rest] = String.split(content, "\n")
    # Finding the closing delimiter
    {block, body} = Enum.split_while(rest, &(&1 != "---"))

    new_block = block ++ ["verified_sha: #{sha}"]
    new_content = Enum.join([frontmatter_delim] ++ new_block ++ body, "\n")
    File.write!(path, new_content)
  end

  defp parse_frontmatter(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.split(contents, "\n") do
          ["---" | rest] ->
            {block, _} = Enum.split_while(rest, &(&1 != "---"))

            Enum.reduce(block, %{}, fn line, acc ->
              case Regex.run(~r/^\s*([\w_]+):\s*(.+?)\s*$/, line) do
                [_, key, value] -> Map.put(acc, String.to_atom(key), value)
                nil -> acc
              end
            end)

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp get_head_sha(nil), do: nil

  defp get_head_sha(checkout) do
    case System.cmd("git", ["-C", checkout, "rev-parse", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  @doc """
  Rejects a candidate memory.
  """
  def reject(path) do
    with {:ok, safe_path} <- validate_candidate_path(path) do
      case File.rm(safe_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:system_error, reason}}
      end
    end
  end

  @doc """
  Returns diff of candidate memory vs shared layer memory of same name (if it exists).
  """
  def diff(path, opts \\ []) do
    with {:ok, safe_path} <- validate_candidate_path(path) do
      memory_root = Keyword.get(opts, :memory_root, Paths.memory_root())
      shared_path = Path.join(memory_root, Path.basename(safe_path))

      if File.exists?(shared_path) do
        {out, _} = System.cmd("diff", ["-u", shared_path, safe_path])
        {:ok, out}
      else
        case File.read(safe_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:system_error, reason}}
        end
      end
    end
  end
end
