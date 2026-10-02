defmodule Arbiter.Test.MemoryFixture do
  @moduledoc """
  Memory files and real git checkouts for the phase-13 memory tests
  (bd-19qve3): the promotion queue, the staleness checker and the mount
  filter all verify citations against a committed tree, so the fixtures are
  real repositories (`Arbiter.Test.GitFixture`), not bare directories.
  """

  alias Arbiter.Test.GitFixture

  @doc "A checkout (a clone with one commit holding `files`) — its path."
  @spec checkout!(%{String.t() => String.t()}) :: String.t()
  def checkout!(files) do
    %{clone: clone} = GitFixture.origin_and_clone(files)
    clone
  end

  @doc "Commit `files` (`:delete` removes one) in `checkout`; returns the new HEAD."
  @spec commit!(String.t(), %{String.t() => String.t() | :delete}) :: String.t()
  def commit!(checkout, files), do: GitFixture.commit!(checkout, files, "change")

  @doc "HEAD of `checkout`."
  @spec head!(String.t()) :: String.t()
  def head!(checkout), do: GitFixture.git!(checkout, ["rev-parse", "HEAD"])

  @doc """
  Memory file text in the shape sessions write: `metadata.type` nested, plus
  `workspace_id` under it when given.
  """
  @spec memory(String.t(), String.t(), keyword()) :: String.t()
  def memory(type, body, opts \\ []) do
    name = Keyword.get(opts, :name, "fixture")

    workspace =
      case Keyword.get(opts, :workspace_id) do
        nil -> ""
        id -> "  workspace_id: #{id}\n"
      end

    extra = Keyword.get(opts, :extra, "")

    """
    ---
    name: #{name}
    description: fixture
    metadata:
      type: #{type}
    #{workspace}#{extra}---

    #{body}
    """
  end

  @doc "Write `memory/3` text to `dir/filename`; returns the path."
  @spec write_memory!(String.t(), String.t(), String.t(), String.t(), keyword()) :: String.t()
  def write_memory!(dir, filename, type, body, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, memory(type, body, Keyword.put_new(opts, :name, Path.rootname(filename))))
    path
  end
end
