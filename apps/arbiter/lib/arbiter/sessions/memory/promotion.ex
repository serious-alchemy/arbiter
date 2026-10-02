defmodule Arbiter.Sessions.Memory.Promotion do
  @moduledoc """
  The promotion queue for candidate memories (bd-19qve3, RFC §9.4 phase 13),
  modelled on the Loop's `loop_pending_*` queue. A session writes candidates
  into its own `<sessions_root>/<session-id>/memory/candidates/`. They reach
  the shared layer that every later session mounts **only** through an
  explicit `promote/2`, and nothing in this module runs on its own. The MCP
  tools in `Arbiter.MCP.Tools.MemoryPending` restrict who may call the writes.

  A candidate is addressed by its id, `"<session-id>/<file>.md"`, exactly as
  `list_candidates/1` prints it. Ids are matched against a strict pattern and
  resolved under `Arbiter.Sessions.Layout`, never taken as paths. Only regular
  files are candidates: a symlink planted in a candidate directory is never
  listed, read or promoted.

  ## Promote

    1. The candidate's own copies of the fields promotion owns (provenance,
       anchors, `verified_sha`, and quarantine and rejection marks) are
       stripped, wherever the session nested them. A session cannot vouch for
       itself.
    2. It is verified against the current `HEAD`
       (`Arbiter.Sessions.Memory.Staleness`, anchoring every `file:line` on the
       line it names now), and refused while anything is stale.
    3. Provenance is stamped into the frontmatter: `source_session`,
       `author_model` (from the session's usage ledger, else its provider),
       `promoted_by`, `promoted_at`, plus `verified_sha` and `anchors`.
    4. The memory is written atomically into the memory root together with its
       verdict, so the next mount serves it without waiting for the checker.
       An existing memory of the same name is replaced only with `overwrite:
       true`, and the replaced copy is kept under `.superseded/`.

  ## Reject

  A rejection marks; it never deletes (amendment 6). The candidate moves to the
  session's `memory/rejected/`, stamped `rejected_at`, `rejected_by` and
  `rejection_reason`, and stays there for audit. `list_candidates(state:
  :rejected)` shows it.
  """

  require Logger

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts

  @session_id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
  @filename ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.md\z/
  @max_bytes 64 * 1024
  @types ~w(user feedback reference project)

  # Fields only promotion, quarantine and rejection may write.
  @reserved ~w(source_session author_model promoted_by promoted_at verified_sha anchors
               restored_by restored_at quarantined_at quarantined_from quarantine_sha
               quarantine_reason rejected_at rejected_by rejection_reason)

  @type candidate :: %{
          required(:id) => String.t(),
          required(:session_id) => String.t(),
          required(:filename) => String.t(),
          required(:state) => :pending | :rejected,
          optional(atom()) => term()
        }

  @type error ::
          :invalid_id
          | :not_found
          | :exists
          | :too_large
          | :reason_required
          | {:invalid_memory, String.t()}
          | {:stale, Staleness.verdict()}
          | {:system_error, term()}

  @doc """
  Every candidate in every session, oldest session directory first.

  ## Options

    * `:state` — `:pending` (default, the queue) or `:rejected` (the audit
      trail of rejections).
    * `:memory_root` — to report whether a candidate would replace a shared
      memory (`replaces_shared`).
  """
  @spec list_candidates(keyword()) :: [candidate()]
  def list_candidates(opts \\ []) do
    state = Keyword.get(opts, :state, :pending)
    root = memory_root(opts)

    case File.ls(Layout.root()) do
      {:ok, sessions} ->
        sessions
        |> Enum.filter(&Regex.match?(@session_id, &1))
        |> Enum.sort()
        |> Enum.flat_map(&session_entries(&1, state, root))

      {:error, _reason} ->
        []
    end
  end

  defp session_entries(session_id, state, root) do
    dir = state_dir(session_id, state)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(@filename, &1))
        |> Enum.sort()
        |> Enum.flat_map(&entry(session_id, &1, dir, state, root))

      {:error, _reason} ->
        []
    end
  end

  defp entry(session_id, filename, dir, state, root) do
    case read_regular(Path.join(dir, filename)) do
      {:ok, contents} -> [summarize(session_id, filename, contents, state, root)]
      {:error, _reason} -> []
    end
  end

  defp summarize(session_id, filename, contents, state, root) do
    fields = Frontmatter.fields(contents)

    base = %{
      id: "#{session_id}/#{filename}",
      session_id: session_id,
      filename: filename,
      state: state,
      name: fields["name"],
      description: fields["description"],
      type: fields["type"],
      workspace_id: fields["workspace_id"],
      bytes: byte_size(contents),
      replaces_shared: File.exists?(Path.join(root, filename))
    }

    if state == :rejected do
      Map.merge(base, %{
        rejected_at: fields["rejected_at"],
        rejected_by: fields["rejected_by"],
        rejection_reason: fields["rejection_reason"]
      })
    else
      base
    end
  end

  @doc """
  One candidate in full: its `content`, a unified `diff` against the shared
  memory it would replace (`nil` for a new one), and the `verification` that
  promotion would run, so a reviewer sees a refusal coming.

  Takes the same options as `promote/2`.
  """
  @spec diff(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def diff(id, opts \\ []) do
    with {:ok, candidate} <- fetch(id) do
      shared = Path.join(memory_root(opts), candidate.filename)

      {:ok,
       %{
         id: candidate.id,
         content: candidate.contents,
         diff: line_diff(shared, candidate),
         verification: verify(candidate, opts)
       }}
    end
  end

  # A whole-file line diff (memories are small): ` ` kept, `-` shared only,
  # `+` candidate only.
  defp line_diff(shared, candidate) do
    case read_regular(shared) do
      {:ok, current} ->
        header = ["--- shared/#{candidate.filename}", "+++ candidate/#{candidate.filename}"]

        body =
          current
          |> String.split("\n")
          |> List.myers_difference(String.split(candidate.contents, "\n"))
          |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &(diff_mark(op) <> &1)) end)

        Enum.join(header ++ body, "\n")

      {:error, _reason} ->
        nil
    end
  end

  defp diff_mark(:eq), do: " "
  defp diff_mark(:del), do: "-"
  defp diff_mark(:ins), do: "+"

  @doc """
  Promote a candidate into the shared layer (see the moduledoc).

  ## Options

    * `:actor` — recorded as `promoted_by` (default `"operator"`).
    * `:overwrite` — replace a shared memory of the same name (default
      `false`); the replaced copy is kept under `.superseded/`.
    * `:memory_root`, `:now`, and everything
      `Arbiter.Sessions.Memory.Staleness.verify_contents/2` accepts.
  """
  @spec promote(String.t(), keyword()) ::
          {:ok, %{memory: String.t(), path: Path.t(), verdict: Staleness.verdict()}}
          | {:error, error()}
  def promote(id, opts \\ []) do
    root = memory_root(opts)

    with {:ok, candidate} <- fetch(id),
         :ok <- check_size(candidate),
         :ok <- check_shape(candidate),
         :ok <- check_target(root, candidate.filename, opts),
         {:ok, contents, verdict} <- verify_and_stamp(candidate, opts) do
      install(root, candidate, contents, verdict, opts)
    end
  end

  defp check_size(%{contents: contents}) do
    if byte_size(contents) <= @max_bytes, do: :ok, else: {:error, :too_large}
  end

  # A memory the mount could never serve is not worth promoting: it needs a
  # known `metadata.type`, and a `project` memory needs the workspace it
  # belongs to (phase 12 mounts one with none for no session).
  defp check_shape(%{contents: contents}) do
    case Frontmatter.fields(contents) do
      %{"type" => "project", "workspace_id" => _} ->
        :ok

      %{"type" => "project"} ->
        {:error, {:invalid_memory, "a project memory needs metadata.workspace_id"}}

      %{"type" => type} when type in @types ->
        :ok

      _ ->
        {:error, {:invalid_memory, "metadata.type must be one of: #{Enum.join(@types, ", ")}"}}
    end
  end

  defp check_target(root, filename, opts) do
    if File.exists?(Path.join(root, filename)) and not Keyword.get(opts, :overwrite, false),
      do: {:error, :exists},
      else: :ok
  end

  defp verify_and_stamp(candidate, opts) do
    verdict = verify(candidate, opts)

    if verdict.status == :stale,
      do: {:error, {:stale, verdict}},
      else: {:ok, stamp(candidate, verdict, opts), verdict}
  end

  defp verify(candidate, opts) do
    candidate.contents
    |> Frontmatter.drop(@reserved)
    |> Staleness.verify_contents(Keyword.put(opts, :establish_anchors, true))
  end

  defp stamp(candidate, verdict, opts) do
    pairs = [
      {"source_session", candidate.session_id},
      {"author_model", author_model(candidate.session_id)},
      {"promoted_by", actor(opts)},
      {"promoted_at", DateTime.to_iso8601(now(opts))},
      {"verified_sha", Staleness.sha_label(verdict.checked_against)},
      {"anchors", Staleness.encode_anchors(verdict.anchors)}
    ]

    candidate.contents
    |> Frontmatter.drop(@reserved)
    |> Frontmatter.put(Enum.reject(pairs, fn {_key, value} -> value in [nil, ""] end))
  end

  defp install(root, candidate, contents, verdict, opts) do
    target = Path.join(root, candidate.filename)
    verdict = %{verdict | content_sha256: Staleness.content_hash(contents)}

    with :ok <- supersede(root, candidate.filename, opts),
         :ok <- Verdicts.write(root, candidate.filename, verdict),
         :ok <- Memory.write_file_atomic(target, contents) do
      consume(candidate)

      Logger.info(
        "Arbiter.Sessions.Memory.Promotion: promoted #{candidate.id} as #{candidate.filename}"
      )

      {:ok, %{memory: candidate.filename, path: target, verdict: verdict}}
    else
      {:error, reason} -> {:error, {:system_error, reason}}
    end
  end

  defp supersede(root, filename, opts) do
    current = Path.join(root, filename)

    if Keyword.get(opts, :overwrite, false) and File.regular?(current) do
      stamp = opts |> now() |> DateTime.to_unix()
      kept = Path.join([root, ".superseded", "#{Path.rootname(filename)}.#{stamp}.md"])

      with :ok <- File.mkdir_p(Path.dirname(kept)), do: File.cp(current, kept)
    else
      :ok
    end
  end

  defp consume(candidate) do
    case File.rm(candidate.path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "promoted #{candidate.id} but could not clear the candidate: #{inspect(reason)}"
        )
    end
  end

  # The model that wrote the candidate, from what Arbiter itself recorded —
  # never from the candidate's own frontmatter.
  defp author_model(session_id) do
    case Sessions.get(session_id) do
      {:ok, session} -> ledger_model(session) || Atom.to_string(session.provider)
      {:error, :not_found} -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp ledger_model(session) do
    session |> Sessions.usage_events() |> Enum.reverse() |> Enum.find_value(& &1.model)
  end

  @doc """
  Reject a candidate with a `reason` (required). Marks and keeps it under the
  session's `memory/rejected/`; never deletes it.

  Options: `:actor` (recorded as `rejected_by`, default `"operator"`), `:now`.
  """
  @spec reject(String.t(), String.t() | nil, keyword()) ::
          {:ok, %{id: String.t(), path: Path.t()}} | {:error, error()}
  def reject(id, reason, opts \\ []) do
    with {:ok, candidate} <- fetch(id),
         {:ok, reason} <- require_reason(reason) do
      file_rejection(candidate, reason, opts)
    end
  end

  defp require_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_reason(_reason), do: {:error, :reason_required}

  defp file_rejection(candidate, reason, opts) do
    dir = state_dir(candidate.session_id, :rejected)
    target = Path.join(dir, free_name(dir, candidate.filename, opts))

    marked =
      Frontmatter.put(candidate.contents, [
        {"rejected_at", DateTime.to_iso8601(now(opts))},
        {"rejected_by", actor(opts)},
        {"rejection_reason", reason}
      ])

    with :ok <- Memory.write_file_atomic(target, marked),
         :ok <- File.rm(candidate.path) do
      {:ok, %{id: candidate.id, path: target}}
    else
      {:error, reason} -> {:error, {:system_error, reason}}
    end
  end

  defp free_name(dir, filename, opts) do
    stem = Path.rootname(filename)

    [filename, "#{stem}.#{opts |> now() |> DateTime.to_unix()}.md"]
    |> Stream.concat(
      Stream.repeatedly(fn -> "#{stem}.#{System.unique_integer([:positive])}.md" end)
    )
    |> Enum.find(&(not File.exists?(Path.join(dir, &1))))
  end

  # ---- addressing ---------------------------------------------------------

  defp fetch(id) do
    with {:ok, session_id, filename} <- parse_id(id),
         path = Path.join(state_dir(session_id, :pending), filename),
         {:ok, contents} <- read_regular(path) do
      {:ok, %{id: id, session_id: session_id, filename: filename, path: path, contents: contents}}
    else
      {:error, :invalid_id} -> {:error, :invalid_id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp parse_id(id) when is_binary(id) do
    with [session_id, filename] <- String.split(id, "/"),
         true <- Regex.match?(@session_id, session_id),
         true <- Regex.match?(@filename, filename) do
      {:ok, session_id, filename}
    else
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_id), do: {:error, :invalid_id}

  defp state_dir(session_id, :pending), do: Layout.memory_candidates_dir(session_id)
  defp state_dir(session_id, :rejected), do: Path.join(Layout.memory_dir(session_id), "rejected")

  # `lstat`, so a symlink is never followed: a session could otherwise point a
  # "candidate" at any file this user can read.
  defp read_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      {:ok, _other} -> {:error, :not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp memory_root(opts), do: Keyword.get_lazy(opts, :memory_root, &Paths.memory_root/0)
  defp actor(opts), do: Keyword.get(opts, :actor, "operator")
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
