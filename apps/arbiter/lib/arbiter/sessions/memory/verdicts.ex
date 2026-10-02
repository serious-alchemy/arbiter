defmodule Arbiter.Sessions.Memory.Verdicts do
  @moduledoc """
  The persisted staleness verdict for each shared memory (bd-19qve3,
  amendment 3): one JSON sidecar per memory under
  `<memory_root>/.verdicts/<basename>.json`, written by
  `Arbiter.Sessions.Memory.Checker`, `Promotion` and `Quarantine`, and **only
  read** by `Arbiter.Sessions.Memory.mount/2`.

  A verdict is bound to the exact bytes it judged (`content_sha256`), so an edit
  to a memory after its check leaves it with no current verdict, and it is not
  served until the checker has looked at it again. Nothing here runs git or
  touches the database: deciding whether to serve is two small file reads.

  Sidecars sit beside the memories rather than in the database for the same
  reason the memories do: the shared layer is a directory the operator can
  read, back up and repair by hand, and a verdict is only meaningful next to the
  file it describes. The dot-directory is invisible to the mount, which reads
  top-level `*.md` files only.
  """

  require Logger

  alias Arbiter.Sessions.Memory.Staleness

  @dir ".verdicts"
  @servable [:ok, :unverified]
  @statuses %{"ok" => :ok, "stale" => :stale, "unverified" => :unverified}
  @kinds %{"file" => :file, "module" => :module, "ticket" => :ticket, "url" => :url}
  @citation_statuses ~w(ok file_missing anchor_missing line_out_of_range undefined missing
                        unverifiable unchecked)a
                     |> Map.new(&{Atom.to_string(&1), &1})

  @doc "Where `basename`'s verdict lives."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(memory_root, basename), do: Path.join([memory_root, @dir, basename <> ".json"])

  @doc """
  The stored verdict for `basename`, or `:none` when there is none or it cannot
  be decoded. An undecodable verdict counts as no verdict, never as a pass.
  """
  @spec read(Path.t(), String.t()) :: {:ok, Staleness.verdict()} | :none
  def read(memory_root, basename) do
    with {:ok, json} <- File.read(path(memory_root, basename)),
         {:ok, map} <- Jason.decode(json),
         {:ok, verdict} <- decode(map) do
      {:ok, verdict}
    else
      _ -> :none
    end
  end

  @doc "Persist `verdict` for `basename`, atomically (write a temp file, then rename)."
  @spec write(Path.t(), String.t(), Staleness.verdict()) :: :ok | {:error, term()}
  def write(memory_root, basename, verdict) do
    target = path(memory_root, basename)
    tmp = "#{target}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, Jason.encode!(encode(basename, verdict))) do
      File.rename(tmp, target)
    end
  end

  @doc "Drop `basename`'s verdict, if any."
  @spec delete(Path.t(), String.t()) :: :ok
  def delete(memory_root, basename) do
    case File.rm(path(memory_root, basename)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not delete verdict for #{basename}: #{inspect(reason)}")
    end
  end

  @doc """
  Whether a mount may serve `contents` as `basename`: the stored verdict must
  exist, be for exactly these bytes, and be `:ok` or `:unverified`.
  """
  @spec servable?(Path.t(), String.t(), binary()) :: boolean()
  def servable?(memory_root, basename, contents) do
    case read(memory_root, basename) do
      {:ok, %{status: status, content_sha256: hash}} when status in @servable ->
        hash == Staleness.content_hash(contents)

      _ ->
        false
    end
  end

  # ---- (de)serialisation -----------------------------------------------------

  defp encode(basename, verdict) do
    verdict
    |> Map.take([:type, :content_sha256, :checked_against, :anchors, :reasons])
    |> Map.merge(%{
      memory: basename,
      status: verdict.status,
      checked_at: DateTime.to_iso8601(verdict.checked_at),
      citations: verdict.citations
    })
  end

  defp decode(%{"status" => status, "content_sha256" => hash, "checked_at" => at} = map)
       when is_binary(hash) and is_binary(at) do
    with {:ok, status} <- Map.fetch(@statuses, status),
         {:ok, checked_at, _offset} <- DateTime.from_iso8601(at),
         {:ok, citations} <- decode_citations(Map.get(map, "citations", [])) do
      {:ok,
       %{
         status: status,
         type: map["type"],
         content_sha256: hash,
         checked_at: checked_at,
         checked_against: string_map(map["checked_against"]),
         citations: citations,
         anchors: string_map(map["anchors"]),
         reasons: Enum.filter(List.wrap(map["reasons"]), &is_binary/1)
       }}
    end
  end

  defp decode(_map), do: :error

  defp decode_citations(list) when is_list(list) do
    decoded = Enum.map(list, &decode_citation/1)

    if Enum.all?(decoded, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(decoded, fn {:ok, citation} -> citation end)},
      else: :error
  end

  defp decode_citations(_), do: :error

  defp decode_citation(%{"kind" => kind, "ref" => ref, "status" => status} = entry)
       when is_binary(ref) do
    with {:ok, kind} <- Map.fetch(@kinds, kind),
         {:ok, status} <- Map.fetch(@citation_statuses, status) do
      citation = %{kind: kind, ref: ref, status: status}

      case entry do
        %{"found_at" => line} when is_integer(line) -> {:ok, Map.put(citation, :found_at, line)}
        _ -> {:ok, citation}
      end
    end
  end

  defp decode_citation(_), do: :error

  defp string_map(map) when is_map(map) do
    for {k, v} <- map, is_binary(k) and is_binary(v), into: %{}, do: {k, v}
  end

  defp string_map(_), do: %{}
end
