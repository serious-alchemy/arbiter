defmodule Arbiter.Worker.CliFetcher.Tarball do
  @moduledoc """
  Extracts the wanted regular files of an npm tarball into an empty staging
  directory. The archive is untrusted: only regular files are extracted (a
  symlink or hard link is skipped), and any member whose path is absolute or
  climbs out with `..` fails the whole extraction before a byte is written.
  """

  @type select :: (String.t() -> {:keep, String.t()} | :skip)

  @doc """
  Extract from `tgz` into `dest` (created, must be empty or new). `select` maps
  an archive path (`package/bin/codex`) to `{:keep, relative_path}` or `:skip`.
  Returns the kept `[{relative_path, mode}]`, sorted.
  """
  @spec extract(Path.t(), Path.t(), select()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def extract(tgz, dest, select) do
    with {:ok, members} <- table(tgz),
         :ok <- check_paths(members),
         wanted = wanted(members, select),
         :ok <- File.mkdir_p(dest),
         :ok <- unpack(tgz, dest, wanted) do
      {:ok, finish(wanted, dest)}
    end
  end

  defp table(tgz) do
    case :erl_tar.table(String.to_charlist(tgz), [:compressed, :verbose]) do
      {:ok, members} -> {:ok, members}
      {:error, reason} -> {:error, {:bad_tarball, reason}}
    end
  end

  defp check_paths(members) do
    bad =
      Enum.find(members, fn {name, _type, _size, _mtime, _mode, _uid, _gid} ->
        unsafe?(to_string(name))
      end)

    case bad do
      nil -> :ok
      {name, _, _, _, _, _, _} -> {:error, {:unsafe_path, to_string(name)}}
    end
  end

  defp unsafe?(name) do
    Path.type(name) == :absolute or ".." in Path.split(name) or String.contains?(name, <<0>>)
  end

  defp wanted(members, select) do
    for {name, :regular, _size, _mtime, mode, _uid, _gid} <- members,
        {:keep, rel} <- [select.(to_string(name))],
        do: {to_string(name), rel, Bitwise.band(mode, 0o777)}
  end

  defp unpack(_tgz, _dest, []), do: :ok

  defp unpack(tgz, dest, wanted) do
    files = Enum.map(wanted, fn {name, _rel, _mode} -> String.to_charlist(name) end)

    case :erl_tar.extract(String.to_charlist(tgz), [
           :compressed,
           {:cwd, String.to_charlist(dest)},
           {:files, files}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:bad_tarball, reason}}
    end
  end

  # Move each extracted member to its relative path; the archive layout
  # (`package/...`) is not part of the cached file name.
  defp finish(wanted, dest) do
    staged = Path.join(dest, ".staged")
    File.mkdir_p!(staged)

    moved =
      for {name, rel, mode} <- wanted do
        target = Path.join(staged, rel)
        File.mkdir_p!(Path.dirname(target))
        File.rename!(Path.join(dest, name), target)
        {rel, mode}
      end

    Enum.sort(moved)
  end

  @doc "Where `extract/3` left the files (`<dest>/.staged`)."
  @spec staged_dir(Path.t()) :: Path.t()
  def staged_dir(dest), do: Path.join(dest, ".staged")
end
