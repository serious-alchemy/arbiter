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

  @doc "Where `session_id`'s JSONL can be read from, or `:not_found`."
  @spec find(String.t() | nil) :: {:ok, source()} | :not_found
  def find(session_id) when is_binary(session_id) and session_id != "" do
    session_id
    |> runs_for()
    |> Enum.find_value(:not_found, fn run ->
      case ClaudeSessionFile.locate(run.config_dir, session_id) do
        {:ok, path} ->
          {:ok, {:file, path}}

        :not_found ->
          if SessionArchive.archived?(run.id), do: {:ok, {:archive, run.id}}
      end
    end)
  end

  def find(_), do: :not_found

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

  defp read({:file, path}), do: File.read(path)
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
