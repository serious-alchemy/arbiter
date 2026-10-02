defmodule Arbiter.Sessions.Memory.Promotion do
  @moduledoc """
  Promotion queue for candidate memories written by sessions.
  """

  alias Arbiter.Config.Paths

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

  @doc """
  Promotes a candidate memory to the shared layer.
  """
  def promote(path, opts \\ []) do
    memory_root = Keyword.get(opts, :memory_root, Paths.memory_root())
    # In production, we'd record verified_sha for project memories.
    # For now, just move the file to memory_root.
    dest = Path.join(memory_root, Path.basename(path))
    File.mkdir_p!(memory_root)
    File.rename!(path, dest)
    :ok
  end

  @doc """
  Rejects a candidate memory.
  """
  def reject(path) do
    File.rm(path)
  end

  @doc """
  Returns diff of candidate memory vs shared layer memory of same name (if it exists).
  """
  def diff(path, opts \\ []) do
    memory_root = Keyword.get(opts, :memory_root, Paths.memory_root())
    shared_path = Path.join(memory_root, Path.basename(path))

    if File.exists?(shared_path) do
      # Very basic diff simulation for now
      {out, _} = System.cmd("diff", ["-u", shared_path, path])
      out
    else
      File.read!(path)
    end
  end
end
