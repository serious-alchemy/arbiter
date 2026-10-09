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
  """

  require Logger
  require Ash.Query

  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.SessionArchive
  alias Arbiter.Workers.Run

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
  `store_dir/0` (`0600`, atomically). Returns the session ids kept. Best-effort:
  never raises, and a dir with no Claude config is a no-op.
  """
  @spec preserve(String.t() | nil) :: [String.t()]
  def preserve(run_tmp) when is_binary(run_tmp) do
    run_tmp
    |> Path.join("claude-config/projects/*/*.jsonl")
    |> Path.wildcard()
    |> Enum.flat_map(&preserve_file/1)
  rescue
    _ -> []
  end

  def preserve(_), do: []

  defp preserve_file(path) do
    sid = Path.basename(path, ".jsonl")
    dest = store_path(sid)
    tmp = dest <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(store_dir()),
         :ok <- File.cp(path, tmp),
         _ = File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, dest) do
      [sid]
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("SessionHistory: cannot preserve #{path}: #{inspect(reason)}")
        []
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
          Logger.info("SessionHistory: seeded session #{session_id} into #{config_dir}")
          :ok
        else
          :not_found -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
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
