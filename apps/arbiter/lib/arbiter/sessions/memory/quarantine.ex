defmodule Arbiter.Sessions.Memory.Quarantine do
  @moduledoc """
  Quarantine for shared memories whose citations no longer resolve
  (bd-19qve3, amendment 4).

  **One representation: a directory move.** A stale memory is moved from
  `<memory_root>/<name>.md` to `<memory_root>/quarantined/<name>.md`, and the
  reason, the SHA it failed against and the time are added to its frontmatter.
  The other lines of the frontmatter are left as they were. A move was chosen
  over a frontmatter `status:` flag for three reasons:

    * A mount symlinks each served file into the session
      (`Arbiter.Sessions.Memory`), so moving the file breaks the link in every
      session **already running**. A status flag would keep serving the stale
      text to those sessions until each one is re-provisioned.
    * The mount reads only top-level `*.md` files, so a quarantined memory is
      excluded by where it is, not by a parser or a stored verdict getting it
      right.
    * The rename is atomic. The memory stops being served in one step. Writing
      the annotation is a second step, and it cannot leave the file served.

  **Restore re-verifies first.** `restore/3` strips the quarantine fields, runs
  `Arbiter.Sessions.Memory.Staleness` against the current `HEAD`, and refuses
  while anything is still stale. It moves the memory back only when the check
  passes, and writes a fresh verdict for it so the next mount serves it. Recorded
  anchors are honoured, including first-use ones, which quarantine writes into
  the frontmatter. So a memory whose cited code changed needs either an edit to
  its citations or an explicit `reanchor: true`, which re-anchors every citation
  on the line it names now. Either way the restore is stamped `restored_by` /
  `restored_at`.

  Moving a file back by hand is safe too: its bytes then have no current
  verdict, so it is not served until the checker has re-verified it.
  """

  require Logger

  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts

  @dir "quarantined"
  @fields ~w(quarantined_at quarantined_from quarantine_sha quarantine_reason)
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\.md\z/

  @type entry :: %{
          name: String.t(),
          quarantined_from: String.t(),
          type: String.t() | nil,
          description: String.t() | nil,
          reason: String.t() | nil,
          sha: String.t() | nil,
          quarantined_at: String.t() | nil
        }

  @doc "The quarantine directory under `memory_root`."
  @spec dir(Path.t()) :: Path.t()
  def dir(memory_root), do: Path.join(memory_root, @dir)

  @doc """
  Move `memory_root/basename` into quarantine and annotate it from `verdict`.
  Returns the name it was filed under, which is `basename` unless an earlier
  quarantine already holds that name.

  Only the bytes the verdict judged are moved: if the file changed since (an
  overwriting promotion landed mid-pass), this is `{:error, :changed}` and the
  file stays where it is for the next check.
  """
  @spec quarantine(Path.t(), String.t(), Staleness.verdict()) ::
          {:ok, String.t()} | {:error, :changed | term()}
  def quarantine(memory_root, basename, verdict) do
    source = Path.join(memory_root, basename)
    name = free_name(memory_root, basename, verdict.checked_at)
    target = Path.join(dir(memory_root), name)

    with :ok <- unchanged(source, verdict),
         :ok <- File.mkdir_p(dir(memory_root)),
         :ok <- File.rename(source, target) do
      annotate(target, basename, verdict)
      Verdicts.delete(memory_root, basename)
      {:ok, name}
    end
  end

  defp unchanged(path, verdict) do
    case File.read(path) do
      {:ok, contents} ->
        if Staleness.content_hash(contents) == verdict.content_sha256,
          do: :ok,
          else: {:error, :changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp free_name(memory_root, basename, at) do
    stem = Path.rootname(basename)

    [basename, "#{stem}.#{DateTime.to_unix(at)}.md"]
    |> Stream.concat(
      Stream.repeatedly(fn -> "#{stem}.#{System.unique_integer([:positive])}.md" end)
    )
    |> Enum.find(&(not File.exists?(Path.join(dir(memory_root), &1))))
  end

  defp annotate(path, basename, verdict) do
    with {:ok, contents} <- File.read(path),
         :ok <-
           Memory.write_file_atomic(
             path,
             Frontmatter.put(contents, annotation(contents, basename, verdict))
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("quarantined #{basename} but could not annotate it: #{inspect(reason)}")
    end
  end

  defp annotation(contents, basename, verdict) do
    [
      {"quarantined_at", DateTime.to_iso8601(verdict.checked_at)},
      {"quarantined_from", basename},
      {"quarantine_sha", Staleness.sha_label(verdict.checked_against)},
      {"quarantine_reason", Enum.join(verdict.reasons, "; ")},
      # A first-use anchor lives only in the verdict, which quarantine drops:
      # keep it with the memory so a restore checks against it.
      {"anchors", first_use_anchors(contents, verdict)}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp first_use_anchors(contents, verdict) do
    if Map.has_key?(Frontmatter.fields(contents), "anchors"),
      do: nil,
      else: Staleness.encode_anchors(verdict.anchors)
  end

  @doc "Every quarantined memory, with why and when it was quarantined."
  @spec list(Path.t()) :: [entry()]
  def list(memory_root) do
    case File.ls(dir(memory_root)) do
      {:ok, names} ->
        names
        |> Enum.filter(&valid_name?/1)
        |> Enum.sort()
        |> Enum.flat_map(&entry(memory_root, &1))

      {:error, _reason} ->
        []
    end
  end

  defp entry(memory_root, name) do
    case read_quarantined(memory_root, name) do
      {:ok, contents} ->
        fields = Frontmatter.fields(contents)

        [
          %{
            name: name,
            quarantined_from: fields["quarantined_from"] || name,
            type: fields["type"],
            description: fields["description"],
            reason: fields["quarantine_reason"],
            sha: fields["quarantine_sha"],
            quarantined_at: fields["quarantined_at"]
          }
        ]

      {:error, _} ->
        []
    end
  end

  @doc """
  Re-verify a quarantined memory and, if nothing is stale any more, serve it
  again under the name it was quarantined from.

  ## Options

    * `:reanchor` — re-anchor every citation on the line it names now, instead
      of honouring the recorded anchors (default `false`).
    * `:actor` — recorded as `restored_by` (default `"operator"`).
    * `:now` — recorded as `restored_at`.
    * Everything `Arbiter.Sessions.Memory.Staleness.verify_contents/2` accepts.

  Returns `{:error, {:stale, verdict}}` while a citation is still stale, and
  `{:error, :exists}` when a live memory already holds the name.
  """
  @spec restore(Path.t(), String.t(), keyword()) ::
          {:ok, %{memory: String.t(), verdict: Staleness.verdict()}}
          | {:error,
             :invalid_name | :not_found | :exists | {:stale, Staleness.verdict()} | term()}
  def restore(memory_root, name, opts \\ []) do
    with :ok <- validate_name(name),
         {:ok, contents} <- read_quarantined(memory_root, name),
         {:ok, target} <- restore_target(memory_root, name, contents),
         {:ok, restored, verdict} <- reverify(contents, opts) do
      write_restored(memory_root, name, target, restored, verdict)
    end
  end

  defp validate_name(name), do: if(valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  defp read_quarantined(memory_root, name) do
    path = Path.join(dir(memory_root), name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      _ -> {:error, :not_found}
    end
  end

  defp restore_target(memory_root, name, contents) do
    from = Frontmatter.fields(contents)["quarantined_from"]
    target = if valid_name?(from), do: from, else: name

    if File.exists?(Path.join(memory_root, target)),
      do: {:error, :exists},
      else: {:ok, target}
  end

  defp reverify(contents, opts) do
    reanchor? = Keyword.get(opts, :reanchor, false)
    stripped = Frontmatter.drop(contents, @fields)
    base = if reanchor?, do: Frontmatter.drop(stripped, ["anchors"]), else: stripped
    verdict = Staleness.verify_contents(base, Keyword.put(opts, :establish_anchors, reanchor?))

    if verdict.status == :stale,
      do: {:error, {:stale, verdict}},
      else: {:ok, stamp(base, verdict, reanchor?, opts), verdict}
  end

  defp stamp(contents, verdict, reanchor?, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    pairs = [
      {"restored_by", Keyword.get(opts, :actor, "operator")},
      {"restored_at", DateTime.to_iso8601(now)},
      {"verified_sha", Staleness.sha_label(verdict.checked_against)},
      {"anchors", if(reanchor?, do: Staleness.encode_anchors(verdict.anchors))}
    ]

    Frontmatter.put(contents, Enum.reject(pairs, fn {_key, value} -> value in [nil, ""] end))
  end

  defp write_restored(memory_root, name, target, restored, verdict) do
    verdict = %{verdict | content_sha256: Staleness.content_hash(restored)}

    with :ok <- Verdicts.write(memory_root, target, verdict),
         :ok <- Memory.write_file_atomic(Path.join(memory_root, target), restored) do
      remove_quarantined(memory_root, name)
      {:ok, %{memory: target, verdict: verdict}}
    end
  end

  defp remove_quarantined(memory_root, name) do
    case File.rm(Path.join(dir(memory_root), name)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "restored #{name} but could not clear its quarantine copy: #{inspect(reason)}"
        )
    end
  end
end
