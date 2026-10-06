defmodule Arbiter.NodeAgent.Secrets do
  @moduledoc """
  Per-run secrets on a node (`docs/design/remote-workers.md` §7.1, §11; RW2/U13).

  `podman run -e NAME` writes the resolved value into the container's OCI
  `config.json` and podman's state DB on the **persistent** graph root, so a
  secret never travels as container env. Instead the value is written to a
  0600 file in a 0700 directory under `$XDG_RUNTIME_DIR` (tmpfs), bind-mounted
  read-only into the container (`Container` `:secrets_file`) and sourced by the
  command wrapper (`Container.secrets_wrapper/1`), so the process has the value
  in its environment while nothing podman persists does.

  Fail closed: with no runtime directory, or one that is not a tmpfs, there is
  nowhere safe to put a secret and `write/3` refuses. It never falls back to
  disk. The file is removed when the container exits and by `remove/2` from the
  reaper (a crashed agent leaves it until then, but only on tmpfs).
  """

  @doc """
  The runtime directory secrets live under: `:runtime_dir`, else
  `$XDG_RUNTIME_DIR`.
  """
  @spec runtime_dir(keyword()) :: {:ok, Path.t()} | {:error, :no_runtime_dir}
  def runtime_dir(opts \\ []) do
    case Keyword.get(opts, :runtime_dir) || System.get_env("XDG_RUNTIME_DIR") do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :no_runtime_dir}
    end
  end

  @doc "The 0700 directory holding run `run`'s secrets."
  @spec dir(Path.t(), String.t()) :: Path.t()
  def dir(runtime_dir, run), do: Path.join([runtime_dir, "arbiter-node", run])

  @doc "Where the secrets file of run `run` is."
  @spec file(Path.t(), String.t()) :: Path.t()
  def file(runtime_dir, run), do: Path.join(dir(runtime_dir, run), "secrets.env")

  @doc """
  Write `secrets` (`%{name => value}`) for `run`. Returns the file's path, or
  `{:ok, nil}` when there are none (nothing is created). Options: `:runtime_dir`,
  `:require_tmpfs` (default `true`; tests turn it off), `:mountinfo` (default
  `/proc/self/mountinfo`; a seam for tests).
  """
  @spec write(String.t(), %{optional(String.t()) => String.t()}, keyword()) ::
          {:ok, Path.t() | nil} | {:error, term()}
  def write(_run, secrets, _opts) when map_size(secrets) == 0, do: {:ok, nil}

  def write(run, secrets, opts) do
    with {:ok, root} <- runtime_dir(opts),
         :ok <- check_tmpfs(root, Keyword.get(opts, :require_tmpfs, true), opts) do
      dir = dir(root, run)
      file = file(root, run)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           {:ok, io} <- File.open(file, [:write, :exclusive]) do
        # The mode is set before a byte of the value is written.
        try do
          with :ok <- File.chmod(file, 0o600),
               :ok <- IO.binwrite(io, render(secrets)) do
            {:ok, file}
          else
            {:error, reason} -> {:error, {:secrets_write_failed, reason}}
          end
        after
          File.close(io)
        end
      else
        {:error, reason} -> {:error, {:secrets_write_failed, reason}}
      end
    end
  end

  @doc "Remove run `run`'s secrets directory (idempotent)."
  @spec remove(Path.t() | nil, String.t()) :: :ok
  def remove(nil, _run), do: :ok

  def remove(runtime_dir, run) do
    dir = dir(runtime_dir, run)
    _ = File.rm(Path.join(dir, "secrets.env"))
    _ = File.rmdir(dir)
    :ok
  end

  @doc "Every run id with a secrets directory under `runtime_dir` (for the reaper)."
  @spec runs(Path.t()) :: [String.t()]
  def runs(runtime_dir) do
    case File.ls(Path.join(runtime_dir, "arbiter-node")) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  @doc "`export NAME='value'` lines; values are single-quoted, so nothing in one is interpreted."
  @spec render(%{optional(String.t()) => String.t()}) :: String.t()
  def render(secrets) do
    secrets
    |> Enum.sort()
    |> Enum.map_join(fn {name, value} -> "export #{name}=#{quote_value(value)}\n" end)
  end

  @doc false
  def quote_value(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # -- tmpfs check ------------------------------------------------------------------

  defp check_tmpfs(_root, false, _opts), do: :ok

  defp check_tmpfs(root, true, opts) do
    case fstype(root, Keyword.get(opts, :mountinfo, "/proc/self/mountinfo")) do
      type when type in ["tmpfs", "ramfs"] -> :ok
      type -> {:error, {:secrets_not_on_tmpfs, root, type}}
    end
  end

  # The filesystem type of the longest mount point that prefixes `path`.
  defp fstype(path, mountinfo) do
    path = Path.expand(path)

    case File.read(mountinfo) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&mount_entry/1)
        |> Enum.filter(fn {mount, _} ->
          path == mount or String.starts_with?(path, mount <> "/") or mount == "/"
        end)
        |> Enum.max_by(fn {mount, _} -> byte_size(mount) end, fn -> {"/", nil} end)
        |> elem(1)

      {:error, _} ->
        nil
    end
  end

  # `36 35 98:0 /root /mnt rw,noatime - ext3 /dev/root rw` — the type is the
  # field after the `-` separator.
  defp mount_entry(line) do
    with [pre, post] <- String.split(line, " - ", parts: 2),
         [_, _, _, _, mount | _] <- String.split(pre, " "),
         [type | _] <- String.split(post, " ") do
      [{unescape(mount), type}]
    else
      _ -> []
    end
  end

  defp unescape(mount), do: String.replace(mount, "\\040", " ")
end
