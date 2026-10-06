defmodule Arbiter.Nodes.Files do
  @moduledoc """
  The primary's content-addressed file shelf for nodes (`docs/design/remote-workers.md`
  §7.3): the provider CLI and `arb` a remote run mounts read-only at
  `/opt/arbiter/cli`. `publish/1` hashes a file the **primary itself chose**
  (never request input) and remembers `sha256 → path`; `GET /nodes/files/<sha256>`
  serves exactly those paths, and a request can name nothing else.

  The shelf is `:persistent_term` (a handful of small entries, read on every
  fetch): it is process-independent, so it needs no supervisor, and a restart
  starts empty, which is right: a spec is built (and its files published) when
  a run is placed, never before.
  """

  @type entry :: %{sha256: String.t(), path: String.t()}

  @doc "Hash `path` (cached by path, size and mtime) and shelve it. `{:ok, sha256}`."
  @spec publish(String.t()) :: {:ok, String.t()} | {:error, term()}
  def publish(path) when is_binary(path) do
    with {:ok, %File.Stat{size: size, mtime: mtime, type: :regular}} <-
           File.stat(path, time: :posix),
         {:ok, sha} <- hash_cached(path, size, mtime) do
      :persistent_term.put({__MODULE__, :sha, sha}, path)
      {:ok, sha}
    else
      {:ok, %File.Stat{}} -> {:error, {:not_a_regular_file, path}}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc "The shelved path for `sha`, if the primary published it."
  @spec lookup(String.t()) :: {:ok, String.t()} | :error
  def lookup(sha) when is_binary(sha) do
    case :persistent_term.get({__MODULE__, :sha, sha}, nil) do
      path when is_binary(path) -> if File.regular?(path), do: {:ok, path}, else: :error
      nil -> :error
    end
  end

  defp hash_cached(path, size, mtime) do
    key = {__MODULE__, :hash, path, size, mtime}

    case :persistent_term.get(key, nil) do
      sha when is_binary(sha) ->
        {:ok, sha}

      nil ->
        sha =
          path
          |> File.stream!(65_536)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        :persistent_term.put(key, sha)
        {:ok, sha}
    end
  rescue
    e in File.Error -> {:error, e.reason}
  end
end
