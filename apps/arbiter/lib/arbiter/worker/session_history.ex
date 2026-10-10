defmodule Arbiter.Worker.SessionHistory do
  @moduledoc """
  Carry a Claude session's JSONL across runs, so `claude --resume <sid>` finds it.

  `--resume` looks the session up in `$CLAUDE_CONFIG_DIR/projects/<slug>/<sid>.jsonl`.
  A containerised (`sandbox.backend: podman`) run gets its own per-run config dir
  (`Arbiter.Worker.ContainerSpawn`), so the prior run's JSONL is not there and the
  CLI exits with "No conversation found with session ID" (bd-atsde3).

  `find/1` locates the history of one session — in the config dir a prior run
  recorded (`Run.config_dir`), else in that run's `Arbiter.Worker.SessionArchive`
  — and `seed/3` copies exactly that one file into a new config dir. Nothing else
  of the prior config dir (credentials, other sessions) is touched.
  `Arbiter.Worker.Dispatch` uses `available?/1` to fall back to a briefing resume
  when the history is gone (pruned, never archived).

  A resume placed on a node (bd-4ic681) gets `seed_redacted/4` instead: the same
  one file, with every known secret and credential-shaped token taken out, since
  that copy leaves the primary (`Arbiter.Worker.ContainerSpawn.remote_spec/3`).
  """

  require Logger
  require Ash.Query

  alias Arbiter.Redaction
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.SessionArchive
  alias Arbiter.Worker.WorkerEnv
  alias Arbiter.Workers.Run

  @max_age_seconds 14 * 86_400

  @type source :: {:file, String.t()} | {:archive, String.t()}

  @doc """
  Directory of the host-side session store: `<output_log_root>/session-history/`,
  one `<session_id>.jsonl` per session.

  A podman run's config dir lives in its run tmp dir and is deleted when the
  worker goes down (a finished run's stop, a server restart, the boot sweep).
  `preserve/1` copies the session out first, so the resume lookup finds it after
  the container and its tmp dir are gone, whether or not the run ever reached
  its completion-time `SessionArchive`.
  """
  @spec store_dir() :: String.t()
  def store_dir, do: Path.join(Arbiter.Worker.OutputLog.root(), "session-history")

  @doc "Absolute path of the stored JSONL for `session_id`."
  @spec store_path(String.t()) :: String.t()
  def store_path(session_id), do: Path.join(store_dir(), session_id <> ".jsonl")

  @doc """
  Copy every session JSONL under `<run_tmp>/claude-config/projects/*/` into
  `store_dir/0` (`0600`, atomically), **redacted** with the run's workspace
  secret values exactly as `Arbiter.Worker.SessionArchive` does — this is a
  second persistence path, and a secret must not escape redaction on it. The
  task is resolved from the `Run` row carrying the session id, else from the
  run tmp dir's label (`RunTmp.create/1`). Returns the session ids kept, and
  prunes entries older than 14 days. Best-effort: never raises, and a dir
  with no Claude config is a no-op.
  """
  @spec preserve(String.t() | nil) :: [String.t()]
  def preserve(run_tmp) when is_binary(run_tmp) do
    kept =
      run_tmp
      |> Path.join("claude-config/projects/*/*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(&preserve_file(&1, run_tmp))

    if kept != [], do: prune()
    kept
  rescue
    _ -> []
  end

  def preserve(_), do: []

  @doc "Remove the stored copy of `session_id` (it has been seeded into a new run)."
  @spec discard(String.t()) :: :ok
  def discard(session_id) when is_binary(session_id) and session_id != "" do
    _ = File.rm(store_path(session_id))
    :ok
  end

  @doc "Delete store entries older than the retention window. Returns the count."
  @spec prune() :: non_neg_integer()
  def prune do
    cutoff = System.os_time(:second) - @max_age_seconds

    case File.ls(store_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(store_dir(), &1))
        |> Enum.count(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{mtime: mtime}} when mtime < cutoff -> File.rm(path) == :ok
            _ -> false
          end
        end)

      _ ->
        0
    end
  end

  defp preserve_file(path, run_tmp) do
    sid = Path.basename(path, ".jsonl")
    dest = store_path(sid)
    tmp = dest <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(store_dir()),
         {:ok, raw} <- File.read(path),
         redacted = Redaction.redact(raw, secret_values(sid, run_tmp)),
         :ok <- check_not_stale(dest, redacted),
         :ok <- File.write(tmp, redacted),
         _ = File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, dest) do
      [sid]
    else
      :stale ->
        []

      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("SessionHistory: cannot preserve #{path}: #{inspect(reason)}")
        []
    end
  end

  # The store is keyed by session id alone, and the boot sweep can reap an older
  # run tmp of the same session after a newer run was preserved. A transcript only
  # grows, so a shorter copy is the stale one: keep the stored entry.
  defp check_not_stale(dest, redacted) do
    case File.stat(dest) do
      {:ok, %File.Stat{size: size}} when size > byte_size(redacted) -> :stale
      _ -> :ok
    end
  end

  defp secret_values(sid, run_tmp) do
    task_id =
      case runs_for(sid) do
        [%{task_id: task_id} | _] -> task_id
        [] -> label_task_id(run_tmp)
      end

    WorkerEnv.secret_values(task_id)
  end

  # `RunTmp.create/1` names dirs `<slug>-<unix seconds>-<unique int>`.
  defp label_task_id(run_tmp) do
    case Regex.run(~r/^(.+)-\d+-\d+$/, Path.basename(run_tmp)) do
      [_, slug] -> slug
      _ -> nil
    end
  end

  @doc "Where `session_id`'s JSONL can be read from, or `:not_found`."
  @spec find(String.t() | nil) :: {:ok, source()} | :not_found
  def find(session_id) when is_binary(session_id) and session_id != "" do
    runs = runs_for(session_id)

    with :not_found <- find_live(runs, session_id),
         :not_found <- find_stored(session_id) do
      find_archived(runs)
    end
  end

  def find(_), do: :not_found

  defp find_live(runs, session_id) do
    Enum.find_value(runs, :not_found, fn run ->
      case ClaudeSessionFile.locate(run.config_dir, session_id) do
        {:ok, path} -> {:ok, {:file, path}}
        :not_found -> nil
      end
    end)
  end

  defp find_stored(session_id) do
    if File.regular?(store_path(session_id)),
      do: {:ok, {:file, store_path(session_id)}},
      else: :not_found
  end

  defp find_archived(runs) do
    case Enum.find(runs, &SessionArchive.archived?(&1.id)) do
      nil -> :not_found
      run -> {:ok, {:archive, run.id}}
    end
  end

  @spec available?(String.t() | nil) :: boolean()
  def available?(session_id), do: match?({:ok, _}, find(session_id))

  @doc """
  Copy `session_id`'s JSONL into `config_dir/projects/<slug of cwd>/`. Already
  present is a success. `{:error, :not_found}` when no source holds it.
  """
  @spec seed(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def seed(config_dir, cwd, session_id) do
    case ClaudeSessionFile.locate(config_dir, session_id) do
      {:ok, _} ->
        :ok

      :not_found ->
        with {:ok, source} <- find(session_id),
             {:ok, bytes} <- read(source),
             dest = destination(config_dir, cwd, session_id),
             :ok <- File.mkdir_p(Path.dirname(dest)),
             :ok <- File.write(dest, bytes) do
          # Only a store-sourced seed discards the entry. When the live file is
          # read instead and the reaper preserves it afterwards, the entry stays
          # until the 14-day `prune/0`.
          if source == {:file, store_path(session_id)}, do: discard(session_id)
          Logger.info("SessionHistory: seeded session #{session_id} into #{config_dir}")
          :ok
        else
          :not_found -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  `seed/3` for a run on **another machine** (a node, bd-4ic681): the copy written
  into `config_dir/projects/<slug of cwd>/<session_id>.jsonl` is redacted
  (`redact_transcript/2` with `secret_values`), because unlike a local seed it
  leaves the primary. A copy already there (an earlier seed of the same run, or
  that run's own upload from its node) is used as it is.

  `{:ok, %{path, bytes, sha256}}`, `path` relative to `config_dir`;
  `{:error, :not_found}` when no source holds the session, `{:error,
  :bad_session_id}` for an id that is not a plain token.
  """
  @spec seed_redacted(String.t(), String.t(), String.t(), [String.t() | nil]) ::
          {:ok, %{path: String.t(), bytes: non_neg_integer(), sha256: String.t()}}
          | {:error, term()}
  def seed_redacted(config_dir, cwd, session_id, secret_values) do
    rel = Path.join(["projects", ClaudeSessionFile.project_slug(cwd), session_id <> ".jsonl"])
    dest = Path.join(config_dir, rel)

    with :ok <- plain_session_id(session_id),
         {:ok, bytes} <- seeded_copy(dest, session_id, secret_values) do
      {:ok,
       %{
         path: rel,
         bytes: byte_size(bytes),
         sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
       }}
    end
  end

  defp plain_session_id(sid) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/, sid),
      do: :ok,
      else: {:error, :bad_session_id}
  end

  # Only a regular file counts as the copy already there: anything else at that path
  # (a link above all) is never read, since what is read here goes to another machine.
  defp seeded_copy(dest, session_id, secret_values) do
    case File.lstat(dest) do
      {:ok, %File.Stat{type: :regular}} ->
        File.read(dest)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_regular_file, type}}

      {:error, :enoent} ->
        with {:ok, source} <- find(session_id),
             {:ok, raw} <- read(source),
             bytes = redact_transcript(raw, secret_values),
             :ok <- File.mkdir_p(Path.dirname(dest)),
             :ok <- File.write(dest, bytes) do
          _ = File.chmod(dest, 0o600)
          Logger.info("SessionHistory: seeded session #{session_id}, redacted, into #{dest}")
          {:ok, bytes}
        else
          :not_found -> {:error, :not_found}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  A session JSONL with every secret taken out, for a copy that leaves the primary:
  each of `secret_values` verbatim and JSON-escaped (as it appears inside a JSON
  string) and then, line by line so a match cannot span two records, the
  credential shapes `Arbiter.Redaction.redact_patterns/1` knows (a token nobody
  registered). Each line stays one JSON record.
  """
  @spec redact_transcript(binary(), [String.t() | nil]) :: binary()
  def redact_transcript(bytes, secret_values) when is_binary(bytes) do
    values =
      for value <- secret_values,
          is_binary(value) and value != "",
          form <- [value, json_escaped(value)],
          uniq: true,
          do: form

    bytes
    |> Redaction.redact(values)
    |> String.split("\n")
    |> Enum.map_join("\n", &Redaction.redact_patterns/1)
  end

  defp json_escaped(value) do
    encoded = Jason.encode!(value)
    binary_part(encoded, 1, byte_size(encoded) - 2)
  end

  @doc "The session id a claude argv resumes (`--resume <sid>`), if any."
  @spec resume_session_id([String.t()] | nil) :: String.t() | nil
  def resume_session_id(argv) when is_list(argv) do
    case Enum.drop_while(argv, &(&1 != "--resume")) do
      ["--resume", sid | _] when is_binary(sid) and sid != "" -> sid
      _ -> nil
    end
  end

  def resume_session_id(_), do: nil

  defp destination(config_dir, cwd, session_id) do
    Path.join([
      config_dir,
      "projects",
      ClaudeSessionFile.project_slug(cwd),
      session_id <> ".jsonl"
    ])
  end

  # A run's tmp dir is reaped asynchronously when its worker stops, so a `:file`
  # source found a moment ago may be gone by the time it is read; the reaper
  # preserves the session into the store first, so fall back to that.
  defp read({:file, path}) do
    case File.read(path) do
      {:error, :enoent} = error ->
        with {sid, ".jsonl"} <- {Path.basename(path, ".jsonl"), Path.extname(path)},
             {:ok, _} <- File.stat(store_path(sid)) do
          File.read(store_path(sid))
        else
          _ -> error
        end

      other ->
        other
    end
  end

  defp read({:archive, run_id}), do: SessionArchive.read(run_id)

  defp runs_for(session_id) do
    Run
    |> Ash.Query.filter(session_id == ^session_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.read!()
  rescue
    _ -> []
  end
end
