defmodule Arbiter.NodeAgent.Retained do
  @moduledoc """
  What the agent keeps of a run the primary no longer knows (`docs/design/remote-workers.md`
  §10.4): a **quiesced** run. After a primary restart the run's Worker is gone, so
  the agent stops the container, takes the snapshot + bundle and the transcript
  tarball *locally* and keeps them on disk, under the run's own directory:

      <node_home>/runs/<run>/retained/manifest.json
                                      checkout.bundle        # unless the run had no shadow
                                      transcripts.tar.gz     # unless it wrote none

  On disk, not in a process, so a retained run survives the agent restarting too,
  and is listed in every `hello` (`inventory.retained`) until it is pulled. The
  primary recovers it with `pull/2` (transcripts first, then the bundle, so a
  transcript is in place by the time the checkout is ingested): both go through
  the ordinary upload endpoints, authorized by the primary's recovery context.
  A pulled run's bundle files are removed; its shadow clone stays until the
  reaper's age rule (24 h) takes it, because it may hold the only copy of
  un-checkpointed work if an ingest was refused.
  """

  alias Arbiter.NodeAgent.{Checkout, Config, Transcripts}

  require Logger

  @manifest "manifest.json"
  @bundle "checkout.bundle"
  @tar "transcripts.tar.gz"

  @doc "The retained directory of `run`."
  @spec dir(Config.t(), String.t()) :: Path.t()
  def dir(%Config{node_home: home}, run), do: Path.join([home, "runs", run, "retained"])

  @doc """
  Retain a quiesced run. `info` is `%{run, task, name, install, branch, base, shadow,
  config_dir}` (`branch` is `nil` for a run with no shadow clone) and `known` the
  shas the primary has. Never raises; a part that could not be taken is recorded in
  the manifest as `%{"error" => reason}`. Returns the manifest.
  """
  @spec retain(Config.t(), map(), [String.t()]) :: map()
  def retain(%Config{} = config, info, known) do
    dir = dir(config, info.run)
    File.mkdir_p!(dir)

    manifest = %{
      "run" => info.run,
      "task" => info.task,
      "name" => info.name,
      "install" => info.install,
      "branch" => info.branch,
      "base" => info.base,
      "retained_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "checkout" => package_checkout(dir, info, known),
      "transcripts" => package_transcripts(dir, info),
      "pulled" => false
    }

    write_manifest(dir, manifest)
    manifest
  end

  defp package_checkout(_dir, %{branch: nil}, _known), do: nil

  defp package_checkout(dir, info, known) do
    dest = Path.join(dir, @bundle)

    case Checkout.package(%{
           shadow: info.shadow,
           run: info.run,
           branch: info.branch,
           known: known,
           dest: dest
         }) do
      {:ok, %{bytes: bytes, snapshot: snapshot, tip: tip}} ->
        %{"bytes" => bytes, "snapshot" => snapshot, "tip" => tip}

      {:error, reason} ->
        Logger.warning(
          "node agent: run #{info.run} could not be bundled for retention: " <>
            inspect(reason, limit: 5, printable_limit: 300)
        )

        %{"error" => inspect(reason, limit: 5, printable_limit: 200)}
    end
  end

  defp package_transcripts(dir, %{config_dir: config_dir}) when is_binary(config_dir) do
    case Transcripts.pack(config_dir, Path.join(dir, @tar)) do
      {:ok, %{files: 0}} ->
        File.rm(Path.join(dir, @tar))
        nil

      {:ok, %{files: files, bytes: bytes}} ->
        %{"files" => files, "bytes" => bytes}

      {:error, reason} ->
        %{"error" => inspect(reason, limit: 5, printable_limit: 200)}
    end
  end

  defp package_transcripts(_dir, _info), do: nil

  @doc "The manifests of every run retained and not yet pulled (what `hello` reports)."
  @spec list(Config.t()) :: [map()]
  def list(%Config{node_home: nil}), do: []

  def list(%Config{node_home: home}) do
    case File.ls(Path.join(home, "runs")) do
      {:ok, runs} -> runs |> Enum.sort() |> Enum.flat_map(&read_unpulled(home, &1))
      {:error, _} -> []
    end
  end

  defp read_unpulled(home, run) do
    case read_manifest(Path.join([home, "runs", run, "retained"])) do
      {:ok, %{"pulled" => false} = manifest} -> [manifest]
      _ -> []
    end
  end

  @doc "The manifest of `run`, if it is retained."
  @spec fetch(Config.t(), String.t()) :: {:ok, map()} | :error
  def fetch(config, run) do
    case read_manifest(dir(config, run)) do
      {:ok, manifest} -> {:ok, manifest}
      _ -> :error
    end
  end

  @doc """
  What `hello` and the `retained` push carry for a manifest: the run id and the
  sizes, nothing the primary has to trust for a path.
  """
  @spec report(map()) :: map()
  def report(manifest) do
    Map.take(manifest, ~w(run task checkout transcripts retained_at))
  end

  @doc """
  Upload a retained run to the primary: the transcripts, then the checkout bundle.
  On success the bundle files go and the manifest says `pulled`. Returns
  `{:ok, %{"transcripts" => _, "checkout" => _}}` (each `"ok"`, `"none"` or
  `"failed: …"`) or `{:error, :not_retained}`; a part that failed leaves the run
  retained so the primary may ask again.
  """
  @spec pull(Config.t(), String.t()) :: {:ok, map()} | {:error, :not_retained}
  def pull(%Config{} = config, run) do
    dir = dir(config, run)

    case read_manifest(dir) do
      {:ok, manifest} ->
        result = %{
          "transcripts" => push(config, run, dir, @tar, manifest["transcripts"], :transcripts),
          "checkout" => push(config, run, dir, @bundle, manifest["checkout"], :checkout)
        }

        if Enum.all?(Map.values(result), &(&1 in ["ok", "none"])) do
          File.rm(Path.join(dir, @tar))
          File.rm(Path.join(dir, @bundle))
          write_manifest(dir, Map.put(manifest, "pulled", true))
        end

        {:ok, result}

      :error ->
        {:error, :not_retained}
    end
  end

  defp push(_config, _run, _dir, _file, nil, _kind), do: "none"
  defp push(_config, _run, _dir, _file, %{"error" => reason}, _kind), do: "failed: " <> reason

  defp push(config, run, dir, file, _meta, kind) do
    path = Path.join(dir, file)

    with {:ok, %File.Stat{size: bytes}} <- File.stat(path),
         {:ok, _} <- put(kind, config, run, path, bytes) do
      "ok"
    else
      {:error, reason} -> "failed: " <> inspect(reason, limit: 5, printable_limit: 200)
    end
  end

  defp put(:transcripts, config, run, path, bytes),
    do: Transcripts.put_tar(config, run, path, bytes)

  defp put(:checkout, config, run, path, bytes), do: Checkout.put_bundle(config, run, path, bytes)

  @doc "Forget `run`'s retained files (the shadow clone is the reaper's)."
  @spec drop(Config.t(), String.t()) :: :ok
  def drop(config, run) do
    File.rm_rf(dir(config, run))
    :ok
  end

  # ---- manifest ------------------------------------------------------------------

  defp write_manifest(dir, manifest) do
    tmp = Path.join(dir, @manifest <> ".tmp")
    File.write!(tmp, Jason.encode!(manifest))
    File.rename!(tmp, Path.join(dir, @manifest))
  end

  defp read_manifest(dir) do
    with {:ok, body} <- File.read(Path.join(dir, @manifest)),
         {:ok, %{"run" => _} = manifest} <- Jason.decode(body) do
      {:ok, manifest}
    else
      _ -> :error
    end
  end
end
