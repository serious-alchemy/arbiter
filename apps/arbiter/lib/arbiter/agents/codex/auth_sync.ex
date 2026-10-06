defmodule Arbiter.Agents.Codex.AuthSync do
  @moduledoc """
  Keeps a podman Codex worker's **copy** of `auth.json` and the operator's real
  one from stranding each other (bd-50d5j6, P8 of
  `docs/design/podman-worker-containers.md`).

  A containerised Codex run gets its own `CODEX_HOME` holding a *copy* of the
  ChatGPT login; the real file is never bind-mounted. The cost of a copy is that
  the CLI's token refresh rotates the refresh token in the copy only, and the
  rotated-out token in the real file is then dead: the operator's next
  `codex` (or the next worker) fails with "refresh token was already used".
  `sync/2` carries the rotation back.

  ## Rule: the newest `last_refresh` wins

  Codex stamps `last_refresh` on every refresh, so the two files can be ordered
  without any bookkeeping about who copied what. That makes every function here
  stateless and idempotent, and safe against sibling runs that rotated in the
  meantime:

    * `sync/2` adopts the run copy into the source **only if** it is valid, is
      the same login as the source (see "Trust" below) and its `last_refresh`
      is strictly newer than the source's and not in the future. An older
      rotation (a sibling run adopted a newer one first) is `:superseded` and
      dropped;
    * `pull/2` is the other direction, for a run that is re-opened (a nudge, an
      auto-resume): if the source is strictly newer than the run copy, the copy
      is replaced, so the run does not resume on a token a sibling rotated away.

  ## Trust: the run copy is worker-controlled

  The worker can write its `codex-home/auth.json`, so `sync/2` treats it as
  untrusted input to the operator's real login. It is adopted only when

    * the real file still exists and is readable. A missing real file means the
      operator logged out (or moved it) during the run; that is never undone
      from a worker's copy (`:superseded`);
    * both files name the same account (`tokens.account_id`, or the same
      `OPENAI_API_KEY`), so a worker cannot swap in another account's login;
    * its `last_refresh` is not more than 5 minutes ahead of the host clock,
      so a forged far-future stamp cannot permanently win the ordering.

  A rotation, which is all this module exists to carry back, satisfies all
  three. What a worker *can* still do is write a well-formed login for the same
  account with a fresh stamp and a junk token; that only breaks the same login
  it was already handed, which it could equally do by exhausting the token.

  ## Safety of the write

  The run copy's parent directory (`codex-home`) is worker-writable too, so
  `sync/2` and `pull/2` refuse (`:invalid` / `:unchanged`) unless it is a real
  directory, not a link to somewhere else on the host.

  The destination is always the `source` path the host computed, never a path
  read from the run directory (a worker can write there). A symlinked source
  (dotfile managers) is written *through*, keeping the link. The new file is
  written beside the real one with mode 0600 and `rename/2`d over it, so a
  reader sees the old or the new file, never half of one, and the whole
  read-compare-write is serialised per file with `:global.trans/3`.
  """

  require Logger

  # How far a run copy's `last_refresh` may run ahead of this host's clock.
  @max_skew_seconds 300

  @type result :: :ok | :no_source | {:error, term()}
  @type sync_result :: :adopted | :unchanged | :superseded | :invalid

  @doc """
  Copy the login at `source` to `run` as a private (0600) regular file. A
  symlink or file already at `run` is removed first, so nothing planted there
  steers the write. `:no_source` when there is no login to share (a keyless
  backend).
  """
  @spec seed(Path.t(), Path.t()) :: result()
  def seed(source, run) do
    case File.read(resolve(source)) do
      {:ok, body} ->
        _ = File.rm(run)
        write_private(run, body)

      {:error, :enoent} ->
        _ = File.rm(run)
        :no_source

      {:error, reason} ->
        {:error, {:source_unreadable, reason}}
    end
  end

  @doc "Carry a rotation in the `run` copy back into `source` (see the moduledoc)."
  @spec sync(Path.t(), Path.t()) :: sync_result()
  def sync(source, run) do
    with {:ok, body} <- read_regular(run),
         {:ok, doc} <- decode(body) do
      locked(source, fn real -> reconcile(real, body, doc) end)
    else
      :missing -> :unchanged
      :invalid -> invalid(run)
    end
  end

  @doc "Replace an unrotated `run` copy with a strictly newer `source` (see the moduledoc)."
  @spec pull(Path.t(), Path.t()) :: :pulled | :unchanged
  def pull(source, run) do
    with true <- real_dir?(Path.dirname(run)),
         {:ok, src_body} <- File.read(resolve(source)),
         {:ok, src} <- decode(src_body),
         true <- newer?(src, run_doc(run)),
         :ok <- write_private(run, src_body) do
      :pulled
    else
      _ -> :unchanged
    end
  end

  # -- internals --------------------------------------------------------------

  defp reconcile(real, body, doc) do
    case File.read(real) do
      {:ok, ^body} -> :unchanged
      {:ok, current} -> adopt_if_trusted(real, body, doc, decode_or_nil(current))
      {:error, _} -> superseded(real)
    end
  end

  # A `current` that is not a login (corrupt) has nothing to protect; anything
  # else must be the same account and strictly older, and the candidate not
  # dated in the future.
  defp adopt_if_trusted(real, body, doc, current) do
    if (current == nil or same_account?(doc, current)) and not future?(doc) and
         newer?(doc, current),
       do: adopt(real, body),
       else: superseded(real)
  end

  defp same_account?(a, b) do
    case {identity(a), identity(b)} do
      {nil, _} -> false
      {id, id} -> true
      _ -> false
    end
  end

  defp identity(%{"tokens" => %{"account_id" => id}}) when is_binary(id) and id != "",
    do: {:account, id}

  defp identity(%{"OPENAI_API_KEY" => key}) when is_binary(key) and key != "",
    do: {:api_key, key}

  defp identity(_), do: nil

  defp future?(doc) do
    case stamp(doc) do
      nil -> false
      dt -> DateTime.diff(dt, DateTime.utc_now()) > @max_skew_seconds
    end
  end

  defp run_doc(run) do
    with {:ok, body} <- read_regular(run), {:ok, doc} <- decode(body), do: doc, else: (_ -> nil)
  end

  defp decode_or_nil(body) do
    case decode(body) do
      {:ok, doc} -> doc
      _ -> nil
    end
  end

  # A run copy (or the directory holding it) that a jailed worker could have
  # swapped for a link must not be followed.
  defp read_regular(path) do
    if real_dir?(Path.dirname(path)), do: read_regular_file(path), else: :invalid
  end

  defp read_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, body} -> {:ok, body}
          {:error, _} -> :missing
        end

      {:ok, _} ->
        :invalid

      {:error, _} ->
        :missing
    end
  end

  # `codex-home` is the only directory below the container's writable bind
  # root, so the worker can replace it with a link to anywhere the host can
  # write; `:exclusive` + `rename/2` only protect the last path component.
  defp real_dir?(dir) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(dir))
  end

  # A login worth keeping carries a refresh token (ChatGPT) or an API key.
  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> if credential?(doc), do: {:ok, doc}, else: :invalid
      _ -> :invalid
    end
  end

  defp credential?(%{"tokens" => %{"refresh_token" => token}}) when is_binary(token),
    do: token != ""

  defp credential?(%{"OPENAI_API_KEY" => key}) when is_binary(key), do: key != ""
  defp credential?(_), do: false

  # `candidate` replaces `current` only when it is provably newer; an undated
  # candidate never wins, an undated `current` always loses.
  defp newer?(candidate, current) do
    case {stamp(candidate), stamp(current)} do
      {nil, _} -> false
      {_, nil} -> true
      {a, b} -> DateTime.compare(a, b) == :gt
    end
  end

  defp stamp(%{"last_refresh" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp stamp(_), do: nil

  defp adopt(real, body) do
    case write_private(real, body) do
      :ok ->
        Logger.warning("Codex.AuthSync: persisted a rotated auth.json into #{real}")
        :adopted

      {:error, reason} ->
        Logger.error("Codex.AuthSync: could not persist rotated auth.json: #{inspect(reason)}")
        :invalid
    end
  end

  defp superseded(real) do
    Logger.warning("Codex.AuthSync: run's auth.json is older than #{real}; not adopting it")
    :superseded
  end

  defp invalid(run) do
    Logger.warning("Codex.AuthSync: run's auth.json #{run} is not a usable login; ignoring it")
    :invalid
  end

  defp locked(source, fun) do
    real = resolve(source)
    :global.trans({{__MODULE__, real}, self()}, fn -> fun.(real) end, [node()], :infinity)
  end

  # Always tmp + rename: `:exclusive` refuses an existing name (including a
  # planted symlink) and `rename/2` replaces a link at `path` instead of
  # following it.
  defp write_private(path, body) do
    tmp = "#{path}.arb-#{System.unique_integer([:positive])}"

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         result = write_open(io, tmp, body),
         :ok <- File.close(io),
         :ok <- result,
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  # Tighten the mode before any secret reaches the file, writing through the
  # open handle so a swap of the name cannot redirect the bytes.
  defp write_open(io, tmp, body) do
    with :ok <- File.chmod(tmp, 0o600), do: IO.binwrite(io, body)
  end

  # Follow symlinks to the file that actually holds the login.
  defp resolve(path, depth \\ 0)
  defp resolve(path, depth) when depth > 8, do: path

  defp resolve(path, depth) do
    case File.read_link(path) do
      {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> resolve(depth + 1)
      {:error, _} -> path
    end
  end
end
