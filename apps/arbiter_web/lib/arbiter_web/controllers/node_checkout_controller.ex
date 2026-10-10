defmodule ArbiterWeb.NodeCheckoutController do
  @moduledoc """
  Checkout sync over HTTPS (`docs/design/remote-workers.md` §9), behind
  `ArbiterWeb.Plugs.NodeAuth`:

    * `GET /nodes/runs/:run/seed.bundle?have=<sha>,<sha>` — the (thin) seed bundle
      for the run (`Arbiter.Nodes.Checkout.seed_bundle/2`).
    * `PUT /nodes/runs/:run/checkout` — the snapshot bundle, with a
      `Content-Length` (cap `Arbiter.Nodes.Checkout.max_bytes/0`, 256 MiB). The body
      is streamed to a private scratch file and ingested through the quarantine
      (`Arbiter.Nodes.Checkout.ingest/2`); nothing a node sends reaches the home
      clone before that has passed.
    * `PUT /nodes/runs/:run/transcripts` — a tar of the run's session JSONL, extracted
      into the run's config dir by the sanitising extractor
      (`Arbiter.Nodes.Transcripts`, §7.6).
    * `GET /nodes/runs/:run/session` — the other direction (bd-4ic681): the
      transcript of the session a `--resume` run continues, which
      `Arbiter.Worker.ContainerSpawn.remote_spec/3` seeded, redacted, into the run's
      config dir and named in its checkout context (`:session`).

  All are authorized the same way: the run must be one **this node's session
  holds** (`Arbiter.Nodes.Session.checkout_context/2`), so a node can neither read
  nor write another node's run, and the path it names is a run id, never a path.
  Every other answer is a `404`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Nodes.{Agent, Checkout, Registry, Session, Transcripts}

  require Logger

  @run_re ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/
  @sha_re ~r/\A[0-9a-f]{40,64}\z/
  @max_have 64
  @chunk 1_048_576

  # ---- seed ------------------------------------------------------------------------

  def seed(conn, %{"run" => run} = params) do
    case authorize(conn, run) do
      {:ok, _pid, ctx} -> seed_run(conn, run, ctx, have(params))
      :error -> error(conn, 404, "Not found")
    end
  end

  # Every scratch path is `<data_home>/node-checkout/<kind>-<run>-<n>`: `run` matched
  # `@run_re` (letters, digits, `-`, `_`) in `authorize/2` and `<n>` is a unique
  # integer, so the request chooses no directory component.
  # sobelow_skip ["Traversal.FileModule"]
  defp seed_run(conn, run, ctx, have) do
    File.mkdir_p!(scratch())
    dest = Path.join(scratch(), "seed-#{run}-#{System.unique_integer([:positive])}.bundle")

    result =
      Checkout.seed_bundle(ctx.home,
        run: run,
        branch: ctx.branch,
        base: ctx.base,
        have: have,
        seeded_paths: Map.get(ctx, :seeded_paths) || [],
        dest: dest
      )

    send_seed(conn, result, dest)
  end

  # `path` is the scratch file this request created; the request named no path.
  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  defp send_seed(conn, {:ok, %{path: path, thin?: thin?}}, dest) do
    conn
    |> put_resp_content_type("application/x-git-bundle")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-bundle-thin", to_string(thin?))
    |> send_file(200, path)
  after
    File.rm(dest)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp send_seed(conn, {:error, reason}, dest) do
    File.rm(dest)
    reject(conn, reason)
  end

  defp have(%{"have" => have}) when is_binary(have) do
    have
    |> String.split(",", trim: true)
    |> Enum.filter(&Regex.match?(@sha_re, &1))
    |> Enum.take(@max_have)
  end

  defp have(_params), do: []

  # ---- session (bd-4ic681) ------------------------------------------------------------

  # The transcript of the session a `--resume` run continues: seeded, redacted, into
  # the run's config dir by `ContainerSpawn.remote_spec/3`, and named by the run's
  # checkout context. The request names a run, never a path.
  def session(conn, %{"run" => run}) do
    case authorize(conn, run) do
      {:ok, _pid, %{config_dir: dir, session: rel}} when is_binary(dir) and is_binary(rel) ->
        send_session(conn, Path.join(dir, rel))

      {:ok, _pid, _ctx} ->
        error(conn, 404, "This run resumes no session")

      :error ->
        error(conn, 404, "Not found")
    end
  end

  # `path` is the run's config dir and the session path its own spawn chose. A link
  # there is not followed: only a regular file is served.
  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  defp send_session(conn, path) do
    if match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)) do
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("cache-control", "no-store")
      |> send_file(200, path)
    else
      error(conn, 404, "This run's session transcript is gone")
    end
  end

  # ---- checkout --------------------------------------------------------------------

  def checkout(conn, %{"run" => run}), do: upload(conn, run, :checkout)
  def transcripts(conn, %{"run" => run}), do: upload(conn, run, :transcripts)

  defp upload(conn, run, kind) do
    case authorize(conn, run) do
      # A reviewer's clone is read-only (bd-cgdhlu): it has no work to hand back.
      {:ok, _pid, %{read_only?: true}} when kind == :checkout ->
        error(conn, 403, "This run's checkout is read-only")

      {:ok, pid, ctx} ->
        checked_upload(conn, pid, run, ctx, kind)

      :error ->
        error(conn, 404, "Not found")
    end
  end

  defp checked_upload(conn, pid, run, ctx, kind) do
    cap = Checkout.max_bytes()

    case declared_length(conn) do
      :missing -> error(conn, 411, "Content-Length is required")
      length when length > cap -> too_large(conn, pid, run, kind, cap, length)
      _length -> locked_ingest(conn, pid, run, ctx, cap, kind)
    end
  end

  defp too_large(conn, pid, run, kind, cap, length) do
    if kind == :checkout, do: Session.checkout_done(pid, run, {:error, {:too_large, length}})
    error(conn, 413, "Bundle exceeds the #{cap} byte cap")
  end

  # One ingest per run at a time: they change the same home clone.
  defp locked_ingest(conn, pid, run, ctx, cap, kind) do
    lock = {{__MODULE__, run, kind}, self()}

    case :global.trans(lock, fn -> ingest(conn, pid, run, ctx, cap, kind) end, [node()], 0) do
      :aborted -> error(conn, 409, "A checkout for this run is already being ingested")
      conn -> conn
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ingest(conn, pid, run, ctx, cap, kind) do
    File.mkdir_p!(scratch())
    upload = Path.join(scratch(), "up-#{run}-#{System.unique_integer([:positive])}.bundle")

    try do
      case receive_body(conn, upload, cap) do
        {:ok, conn} ->
          ingest_file(conn, pid, run, ctx, upload, kind)

        {:error, :too_large, conn} ->
          if kind == :checkout, do: Session.checkout_done(pid, run, {:error, {:too_large, cap}})
          error(conn, 413, "Bundle exceeds the #{cap} byte cap")

        {:error, reason, conn} ->
          error(conn, 400, "Upload failed: #{inspect(reason)}")
      end
    after
      File.rm(upload)
    end
  end

  defp ingest_file(conn, _pid, _run, %{config_dir: dir}, upload, :transcripts)
       when is_binary(dir) do
    case Transcripts.extract(upload, dir) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> reject(conn, reason)
    end
  end

  defp ingest_file(conn, _pid, _run, _ctx, _upload, :transcripts),
    do: error(conn, 409, "This run has no config dir to extract transcripts into")

  defp ingest_file(conn, pid, run, ctx, upload, :checkout) do
    ctx =
      ctx
      |> Map.take([:home, :branch, :base, :seeded_paths])
      |> Map.merge(%{run: run, scratch: scratch()})

    case Checkout.ingest(upload, ctx) do
      {:ok, result} ->
        Session.checkout_done(pid, run, {:ok, result})
        json(conn, Map.take(result, [:head, :snapshot, :status_hash, :filtered]))

      {:error, reason} ->
        Logger.warning(
          "node checkout for run #{run} rejected: #{inspect(reason, limit: 5, printable_limit: 300)}"
        )

        Session.checkout_done(pid, run, {:error, reason})
        reject(conn, reason)
    end
  end

  defp declared_length(conn) do
    with [value | _] <- get_req_header(conn, "content-length"),
         {length, ""} when length >= 0 <- Integer.parse(value) do
      length
    else
      _ -> :missing
    end
  end

  # Stream to `path`, refusing past `cap` however much the request declared.
  # sobelow_skip ["Traversal.FileModule"]
  defp receive_body(conn, path, cap) do
    file = File.open!(path, [:write, :binary])

    try do
      read_loop(conn, file, 0, cap)
    after
      File.close(file)
    end
  end

  defp read_loop(conn, file, total, cap) do
    case Plug.Conn.read_body(conn, length: @chunk, read_length: @chunk, read_timeout: 60_000) do
      {:ok, data, conn} -> write(conn, file, data, total, cap, :done)
      {:more, data, conn} -> write(conn, file, data, total, cap, :more)
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp write(conn, _file, data, total, cap, _mode) when total + byte_size(data) > cap,
    do: {:error, :too_large, conn}

  defp write(conn, file, data, total, cap, mode) do
    :ok = IO.binwrite(file, data)

    case mode do
      :done -> {:ok, conn}
      :more -> read_loop(conn, file, total + byte_size(data), cap)
    end
  end

  # ---- shared ----------------------------------------------------------------------

  defp authorize(conn, run) do
    node = conn.assigns[:current_node]

    with true <- is_binary(run) and Regex.match?(@run_re, run),
         true <- not is_nil(node),
         pid when is_pid(pid) <- Registry.lookup(node.id),
         {:ok, ctx} <- Session.checkout_context(pid, run) do
      {:ok, pid, ctx}
    else
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp scratch, do: Path.join(Agent.data_home(), "node-checkout")

  defp reject(conn, {:veto, kind, detail}) do
    conn
    |> put_status(422)
    |> json(%{
      error: %{
        message: "Run cannot be placed on a node: #{kind}",
        veto: to_string(kind),
        detail: to_string(detail)
      }
    })
  end

  defp reject(conn, {:too_large, _}), do: error(conn, 413, "Bundle too large")

  defp reject(conn, {:prerequisites_missing, _}),
    do: error(conn, 409, "Bundle prerequisites are not on the primary")

  defp reject(conn, :no_branch), do: error(conn, 404, "Not found")

  defp reject(conn, reason)
       when is_tuple(reason) or is_atom(reason),
       do: error(conn, 422, "Checkout refused: #{summary(reason)}")

  defp summary({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp summary({tag, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp summary(tag) when is_atom(tag), do: Atom.to_string(tag)

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message}})
  end
end
