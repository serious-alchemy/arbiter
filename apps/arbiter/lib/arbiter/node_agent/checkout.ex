defmodule Arbiter.NodeAgent.Checkout do
  @moduledoc """
  The node half of checkout sync (`docs/design/remote-workers.md` §9): the
  **shadow clone** a run works in, and the snapshot bundle it hands back.

  ## Seed

  `seed/1` fetches the seed bundle the primary built (`Arbiter.Nodes.Checkout.seed_bundle/2`,
  served at `GET /nodes/runs/:run/seed.bundle?have=…`) into the node's shared
  object store (`<node_home>/repos/<slug>.git`, under `refs/arbiter/in/<run>/*`) and builds
  the shadow from it: a private clone with its own `.git` whose objects borrow the
  store through `objects/info/alternates`, the branch at the seeded tip, and, when
  the bundle carries a checkpoint, the work tree restored to it.
  It returns `known`, the shas the primary has, which are the `^prerequisites` of
  every bundle sent back, and `have`, what the store holds, for the next seed.

  ## Snapshot and package

  `package/1` never runs git *in* the shadow: its `.git` is writable by the
  container, so `core.fsmonitor`, a clean/smudge filter or a hook planted in it
  would otherwise run as the agent's user. Instead a fresh bare repo owned by
  the agent borrows the shadow's objects, `git add -A` runs there with
  `--work-tree` pointing at the shadow (a temporary index, so the shadow's own
  index is neither read nor changed), and the shadow's refs are read as plain
  files. The exclude file the shadow's `.git/info/exclude` holds is honoured as
  a bandwidth optimisation only; the primary re-filters.

  The snapshot is a commit on top of the run branch tip at
  `refs/arbiter/snapshot/<run>`. The bundle carries it, and the branch ref when
  the run committed, with `^known` prerequisites. Untracked payload over
  `max_untracked_bytes` (default 50 MB) is vetoed before anything is hashed.
  """

  alias Arbiter.NodeAgent.Config
  alias Arbiter.Nodes.Checkout, as: Primary
  alias Arbiter.Nodes.Checkout.Git

  @sha_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  # ---- seed --------------------------------------------------------------------------

  @doc """
  Build the shadow. `%{store, shadow, bundle, run, branch, base}`.
  `{:ok, %{known, have, head}}`.
  """
  @spec seed(map()) :: {:ok, map()} | {:error, term()}
  def seed(%{store: store, shadow: shadow, bundle: bundle, run: run, branch: branch} = args) do
    prefix = "refs/arbiter/in/#{run}"

    with :ok <- init_store(store),
         {:ok, heads} <- heads(store, bundle),
         picked = pick(heads, branch, args[:base]),
         {:ok, _} <- fetch(store, bundle, picked, prefix),
         {:ok, shas} <- resolve(store, picked, prefix),
         :ok <- build_shadow(store, shadow, branch, args[:base], shas) do
      known = shas |> Map.values() |> Enum.uniq()
      {:ok, %{known: known, have: have(store), head: shas.head}}
    end
  end

  defp init_store(store) do
    if File.exists?(Path.join(store, "HEAD")) do
      :ok
    else
      File.mkdir_p!(store)

      with {:ok, _} <- Git.run(["init", "-q", "--bare", store]),
           {:ok, _} <- Git.run(["config", "fetch.fsckObjects", "true"], git_dir: store) do
        :ok
      end
    end
  end

  defp heads(store, bundle) do
    case Git.run(["bundle", "list-heads", bundle], git_dir: store) do
      {:ok, out} ->
        {:ok, for(line <- String.split(out, "\n", trim: true), [_sha, ref] <- [String.split(line, " ", parts: 2)], do: ref)}

      {:error, {:git, _, out}} ->
        {:error, {:bad_bundle, out}}
    end
  end

  # name in the bundle => where it goes in the store
  defp pick(heads, branch, base) do
    base_refs = if base, do: ["refs/remotes/origin/" <> base, "refs/heads/" <> base], else: []

    [
      {:head, "refs/heads/" <> branch},
      {:base, Enum.find(base_refs, &(&1 in heads))},
      {:checkpoint, Enum.find(heads, &String.starts_with?(&1, "refs/arbiter/checkpoint/"))}
    ]
    |> Enum.filter(fn {_name, ref} -> ref in heads end)
  end

  defp fetch(store, bundle, picked, prefix) do
    specs = for {name, ref} <- picked, do: "+#{ref}:#{prefix}/#{name}"
    Git.run(["fetch", "-q", "--no-tags", bundle] ++ specs, git_dir: store)
  end

  defp resolve(store, picked, prefix) do
    shas =
      for {name, _ref} <- picked,
          sha = Git.rev_parse(store, "#{prefix}/#{name}"),
          into: %{},
          do: {name, sha}

    if Map.has_key?(shas, :head), do: {:ok, shas}, else: {:error, :no_branch_in_seed}
  end

  defp have(store) do
    case Git.run(["for-each-ref", "--format=%(objectname)", "refs/arbiter/in"], git_dir: store) do
      {:ok, out} -> out |> String.split("\n", trim: true) |> Enum.uniq()
      _ -> []
    end
  end

  defp build_shadow(store, shadow, branch, base, shas) do
    File.rm_rf!(shadow)
    File.mkdir_p!(Path.dirname(shadow))
    dot_git = Path.join(shadow, ".git")

    with {:ok, _} <- Git.run(["init", "-q", "-b", branch, shadow]),
         :ok <- File.write(Path.join(dot_git, "objects/info/alternates"), Path.join(store, "objects") <> "\n"),
         {:ok, _} <- Git.run(["config", "user.name", "arbiter"], git_dir: dot_git),
         {:ok, _} <- Git.run(["config", "user.email", "arbiter@localhost"], git_dir: dot_git),
         {:ok, _} <- Git.run(["update-ref", "refs/heads/" <> branch, shas.head], git_dir: dot_git),
         :ok <- base_ref(dot_git, base, shas),
         {:ok, _} <- Git.run(["reset", "-q", "--hard", "HEAD"], git_dir: dot_git, work_tree: shadow) do
      restore_checkpoint(dot_git, shadow, shas)
    end
  end

  defp base_ref(dot_git, base, %{base: sha}) when is_binary(base) do
    with {:ok, _} <- Git.run(["update-ref", "refs/remotes/origin/" <> base, sha], git_dir: dot_git),
         do: :ok
  end

  defp base_ref(_dot_git, _base, _shas), do: :ok

  defp restore_checkpoint(dot_git, shadow, %{checkpoint: snap, head: head}) do
    opts = [git_dir: dot_git, work_tree: shadow]

    with {:ok, _} <- Git.run(["read-tree", "-u", "--reset", snap], opts),
         {:ok, _} <- Git.run(["reset", "-q", "--mixed", head], opts) do
      :ok
    end
  end

  defp restore_checkpoint(_dot_git, _shadow, _shas), do: :ok

  # ---- snapshot + package ------------------------------------------------------------

  @doc """
  Snapshot the shadow and bundle it. `%{shadow, run, branch, known, dest}` plus
  an optional `:max_untracked_bytes`.

  `{:ok, %{path, bytes, snapshot, tip}}`, or `{:error, {:veto, :untracked_size, _}}`
  when the shadow holds too much untracked payload.
  """
  @spec package(map()) :: {:ok, map()} | {:error, term()}
  def package(%{shadow: shadow, run: run, branch: branch, known: known, dest: dest} = args) do
    snap_dir = Path.join(Path.dirname(shadow), "snap-#{run}.git")
    cap = Map.get(args, :max_untracked_bytes) || Primary.max_untracked_bytes()

    try do
      with {:ok, tip} <- read_ref(shadow, "refs/heads/" <> branch),
           :ok <- init_snap(snap_dir, shadow),
           :ok <- untracked_cap(snap_dir, shadow, tip, cap),
           {:ok, snapshot} <- snapshot(snap_dir, shadow, tip, run, branch),
           {:ok, bytes} <- bundle(snap_dir, run, branch, tip, known, dest) do
        {:ok, %{path: dest, bytes: bytes, snapshot: snapshot, tip: tip}}
      end
    after
      File.rm_rf(snap_dir)
    end
  end

  # A ref, read as a file (loose, then packed-refs): git is not run in the shadow.
  defp read_ref(shadow, ref) do
    dot_git = Path.join(shadow, ".git")

    with :error <- loose(dot_git, ref),
         :error <- packed(dot_git, ref) do
      {:error, {:no_ref, ref}}
    end
  end

  defp loose(dot_git, ref) do
    with {:ok, body} <- File.read(Path.join(dot_git, ref)),
         sha = String.trim(body),
         true <- Regex.match?(@sha_re, sha) do
      {:ok, sha}
    else
      _ -> :error
    end
  end

  defp packed(dot_git, ref) do
    with {:ok, body} <- File.read(Path.join(dot_git, "packed-refs")),
         [_, sha] <- Regex.run(~r/^([0-9a-f]{40,64}) #{Regex.escape(ref)}$/m, body) do
      {:ok, sha}
    else
      _ -> :error
    end
  end

  defp init_snap(snap_dir, shadow) do
    File.rm_rf!(snap_dir)
    exclude = Path.join(shadow, ".git/info/exclude")

    with {:ok, _} <- Git.run(["init", "-q", "--bare", snap_dir]),
         {:ok, _} <- Git.run(["config", "core.excludesFile", exclude], git_dir: snap_dir),
         {:ok, _} <- Git.run(["config", "core.autocrlf", "false"], git_dir: snap_dir) do
      File.write(
        Path.join(snap_dir, "objects/info/alternates"),
        Path.join(shadow, ".git/objects") <> "\n"
      )
    end
  end

  defp index(snap_dir), do: [{"GIT_INDEX_FILE", Path.join(snap_dir, "snap-index")}]

  # Untracked = in the work tree, not in the tip's tree, not ignored. Measured
  # with lstat before anything is hashed.
  defp untracked_cap(snap_dir, shadow, tip, cap) do
    opts = [git_dir: snap_dir, work_tree: shadow, env: index(snap_dir)]

    with {:ok, _} <- Git.run(["read-tree", tip], opts),
         {:ok, out} <- Git.run(["ls-files", "-o", "-z", "--exclude-standard"], opts) do
      bytes =
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.reduce(0, fn path, acc ->
          case File.lstat(Path.join(shadow, path)) do
            {:ok, %{type: :regular, size: size}} -> acc + size
            _ -> acc
          end
        end)

      File.rm(Path.join(snap_dir, "snap-index"))

      if bytes > cap,
        do: {:error, {:veto, :untracked_size, "#{bytes} bytes untracked, cap #{cap}"}},
        else: :ok
    end
  end

  defp snapshot(snap_dir, shadow, tip, run, branch) do
    opts = [git_dir: snap_dir, work_tree: shadow, env: index(snap_dir)]

    with {:ok, _} <- Git.run(["add", "-A"], opts),
         {:ok, tree} <- Git.run(["write-tree"], opts),
         {:ok, snap} <- Git.run(["commit-tree", "-p", tip, "-m", "arbiter snapshot", tree], opts),
         {:ok, _} <- Git.run(["update-ref", Primary.snapshot_ref(run), snap], git_dir: snap_dir),
         {:ok, _} <- Git.run(["update-ref", "refs/heads/" <> branch, tip], git_dir: snap_dir) do
      File.rm(Path.join(snap_dir, "snap-index"))
      {:ok, snap}
    end
  end

  defp bundle(snap_dir, run, branch, tip, known, dest) do
    prerequisites =
      known
      |> Enum.filter(&Git.exists?(snap_dir, &1 <> "^{commit}"))
      |> Enum.map(&("^" <> &1))

    refs =
      if tip in known,
        do: [Primary.snapshot_ref(run)],
        else: ["refs/heads/" <> branch, Primary.snapshot_ref(run)]

    File.mkdir_p!(Path.dirname(dest))
    File.rm(dest)

    with {:ok, _} <- Git.run(["bundle", "create", dest] ++ refs ++ prerequisites, git_dir: snap_dir),
         {:ok, %{size: size}} <- File.stat(dest) do
      {:ok, size}
    else
      {:error, {:git, _, out}} -> {:error, {:bundle_failed, out}}
      {:error, _} = error -> error
    end
  end

  # ---- talking to the primary --------------------------------------------------------

  @doc "The node's shared object store for primary repos."
  @spec store(Config.t()) :: Path.t()
  def store(%Config{node_home: home}), do: Path.join([home, "repos", "primary.git"])

  @doc """
  The whole seed: `GET /nodes/runs/<run>/seed.bundle?have=<store tips>` with the node
  credential, then `seed/1`. `{:error, {:veto, kind}}` when the primary refuses the
  repo (submodules, LFS); `{:error, {:http, status}}` otherwise.
  """
  @spec seed_from_primary(Config.t(), %{run: String.t(), branch: String.t(), base: String.t() | nil}, Path.t()) ::
          {:ok, map()} | {:error, term()}
  def seed_from_primary(%Config{} = config, %{run: run} = co, shadow) do
    store = store(config)
    bundle = Path.join([config.node_home, "runs", run, "seed.bundle"])
    File.mkdir_p!(Path.dirname(bundle))

    try do
      with :ok <- init_store(store),
           :ok <- download(config, run, have(store), bundle) do
        seed(%{store: store, shadow: shadow, bundle: bundle, run: run, branch: co.branch, base: co.base})
      end
    after
      File.rm(bundle)
    end
  end

  # A 200 body is the bundle, streamed to `dest`; any other status is a small JSON
  # error, kept in memory so a veto can be read out of it.
  defp download(config, run, have, dest) do
    io = File.open!(dest, [:write, :binary])

    sink = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        :ok = IO.binwrite(io, data)
        {:cont, {req, resp}}
      else
        {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
      end
    end

    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/runs/#{run}/seed.bundle"),
          params: [have: Enum.join(Enum.take(have, 64), ",")],
          headers: [{"authorization", "Bearer " <> config.credential}],
          decode_body: false,
          into: sink,
          retry: false,
          receive_timeout: 600_000
        ] ++ (config.req_options || [])
      )

    try do
      case Req.get(request) do
        {:ok, %Req.Response{status: 200}} -> :ok
        {:ok, %Req.Response{status: status, body: body}} -> {:error, error_of(status, body)}
        {:error, reason} -> {:error, {:download_failed, reason}}
      end
    after
      File.close(io)
    end
  end

  # A refusal's JSON body names the veto.
  defp error_of(status, body) do
    case Jason.decode(to_string(body)) do
      {:ok, %{"error" => %{"veto" => kind}}} -> {:veto, kind}
      _ -> {:http, status}
    end
  end

  @doc """
  Snapshot the shadow and `PUT /nodes/runs/<run>/checkout`. `known` is what the
  primary told the node at seed. `{:ok, response}` is the primary's ingest
  summary; a node-side or primary-side veto is `{:error, {:veto, ...}}`.
  """
  @spec upload(Config.t(), map(), Path.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def upload(%Config{} = config, %{run: run, branch: branch}, shadow, known) do
    dest = Path.join([config.node_home, "runs", run, "checkout.bundle"])

    try do
      with {:ok, %{path: path, bytes: bytes}} <-
             package(%{shadow: shadow, run: run, branch: branch, known: known, dest: dest}),
           {:ok, response} <- put(config, run, path, bytes) do
        {:ok, response}
      end
    after
      File.rm(dest)
    end
  end

  defp put(config, run, path, bytes) do
    request =
      Req.new(
        [
          url: Config.http_url(config, "/nodes/runs/#{run}/checkout"),
          method: :put,
          headers: [
            {"authorization", "Bearer " <> config.credential},
            {"content-type", "application/x-git-bundle"},
            {"content-length", Integer.to_string(bytes)}
          ],
          body: File.stream!(path, 65_536),
          retry: false,
          receive_timeout: 600_000
        ] ++ (config.req_options || [])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:rejected, status, body}}
      {:error, reason} -> {:error, {:upload_failed, reason}}
    end
  end
end
