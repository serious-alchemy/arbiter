defmodule Arbiter.Nodes.Checkout do
  @moduledoc """
  The primary half of checkout sync for runs on a node (`docs/design/remote-workers.md`
  §9; the home/shadow model of bd-aowisc §4.4): **bundles over HTTPS**, and no
  host-side git ever reads the node's `.git`.

  ## Seed (primary → node)

  `seed_bundle/2` builds the bundle a node `GET`s: the run branch, the base
  branch's remote-tracking ref, and the run's last checkpoint when there is
  one. It is **thin** (`^<have>` prerequisites) against the shas the node says it
  already holds, and a full bundle when `have` is empty, names only unknown
  shas, or would leave nothing to send. A repo `veto/2` refuses (submodules,
  LFS) is never seeded.

  ## Ingest (node → primary): a quarantine, in this order

  `ingest/2` takes the uploaded bundle and

    1. enforces the size cap;
    2. `git bundle verify`s it (prerequisites and connectivity, **not** content);
    3. rejects it unless every ref in `list-heads` is on the allowlist
       (`refs/heads/<run branch>`, `refs/arbiter/snapshot/<run>`,
       `refs/remotes/origin/<base>`);
    4. fetches the allowed refs into a **throwaway bare repo** with
       `fetch.fsckObjects` and `transfer.fsckObjects`, `--no-tags`, and
       `core.hooksPath=/dev/null`. **fsck is the gate** (RW2 U7): a tree
       carrying `.git/config` or hooks dies here and no ref lands;
    5. bounds the object count and checks the snapshot is a child of the run tip;
    6. applies the **authoritative path filter** (`Inspect.denied/3`: the
       `Worktree` exclude set plus the run's seeded paths) to the snapshot tree,
       rewriting the snapshot without those paths. The node's own exclude file
       lives in the container-writable shadow `.git` and is only a bandwidth
       optimisation;
    7. checks the vetoes (submodules, LFS, untracked payload over 50 MB);

  and only then fetches the snapshot into the home clone and hands off: the
  branch is forced to the fetched tip, `read-tree -u --reset <snapshot>` and
  `reset --mixed <tip>` make the uncommitted work read as uncommitted. The
  result carries `{head, status_hash}` for the commit gate.

  The committed history is not rewritten: a commit that adds an injected-config
  path is still caught by the commit gate's `has_injected_config_in_commits?/2`.

  Every git call goes through `Arbiter.Nodes.Checkout.Git` (hooks off, no user
  config), including the ones in the home clone.

  ## Checkpoints

  Each ingest keeps the filtered snapshot at `refs/arbiter/checkpoint/<run>` in
  the home clone. `restore/3` re-applies it to the home clone, and the next
  `seed_bundle/2` for the run carries it, so a replacement node's shadow starts
  from the same uncommitted state.
  """

  alias Arbiter.Nodes.Checkout.{Git, Inspect}

  @default_max_bytes 256 * 1024 * 1024
  @default_max_untracked_bytes 50_000_000
  @default_max_objects 500_000
  @default_seed_max_bytes 1024 * 1024 * 1024

  @type ctx :: %{
          required(:run) => String.t(),
          required(:branch) => String.t(),
          required(:base) => String.t(),
          required(:home) => Path.t(),
          required(:scratch) => Path.t(),
          optional(:max_bytes) => pos_integer(),
          optional(:max_untracked_bytes) => non_neg_integer(),
          optional(:max_objects) => pos_integer(),
          optional(:seeded_paths) => [String.t()]
        }

  @doc "The default upload cap, in bytes (`:node_checkout_max_bytes` overrides it)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:arbiter, :node_checkout_max_bytes, @default_max_bytes)

  @doc "The default untracked-payload cap, in bytes."
  @spec max_untracked_bytes() :: non_neg_integer()
  def max_untracked_bytes,
    do: Application.get_env(:arbiter, :node_checkout_max_untracked_bytes, @default_max_untracked_bytes)

  def snapshot_ref(run), do: "refs/arbiter/snapshot/" <> run
  def checkpoint_ref(run), do: "refs/arbiter/checkpoint/" <> run

  # ---- placement veto ----------------------------------------------------------------

  @doc """
  The placement veto on `rev` of the repo at `repo`: `:ok`, or
  `{:error, {:veto, :submodule | :lfs, path}}`.
  """
  @spec veto(Path.t(), String.t()) :: :ok | {:error, term()}
  def veto(repo, rev) do
    with {:ok, git_dir} <- Git.git_dir(repo),
         {:ok, entries} <- Inspect.entries(git_dir, rev) do
      Inspect.veto(git_dir, entries)
    end
  end

  # ---- seed --------------------------------------------------------------------------

  @doc """
  Build the seed bundle for a run into `opts[:dest]`.

  Options: `:run`, `:branch`, `:base` (names), `:have` (shas the node holds),
  `:dest`, `:max_bytes`. Returns `{:ok, %{path, bytes, thin?, refs}}`, where
  `refs` is `%{ref => sha}` as the bundle carries them.
  """
  @spec seed_bundle(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def seed_bundle(home, opts) do
    run = Keyword.fetch!(opts, :run)
    branch = Keyword.fetch!(opts, :branch)
    dest = Keyword.fetch!(opts, :dest)

    with {:ok, git_dir} <- Git.git_dir(home),
         branch_ref = "refs/heads/" <> branch,
         tip when is_binary(tip) <- Git.rev_parse(git_dir, branch_ref) || {:error, :no_branch},
         :ok <- veto(home, tip),
         refs = seed_refs(git_dir, run, branch_ref, Keyword.get(opts, :base)),
         have = known_shas(git_dir, Keyword.get(opts, :have, [])),
         {:ok, thin?} <- create_seed(git_dir, refs, have, dest),
         {:ok, bytes} <- seed_size(dest, Keyword.get(opts, :max_bytes, seed_max_bytes())),
         {:ok, heads} <- list_heads(git_dir, dest) do
      {:ok, %{path: dest, bytes: bytes, thin?: thin?, refs: Map.new(heads, fn {sha, ref} -> {ref, sha} end)}}
    end
  end

  defp seed_max_bytes,
    do: Application.get_env(:arbiter, :node_seed_max_bytes, @default_seed_max_bytes)

  defp seed_refs(git_dir, run, branch_ref, base) do
    base_refs = if base, do: ["refs/remotes/origin/" <> base, "refs/heads/" <> base], else: []

    [
      branch_ref,
      Enum.find(base_refs, &Git.rev_parse(git_dir, &1)),
      Enum.find([checkpoint_ref(run)], &Git.rev_parse(git_dir, &1))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp known_shas(git_dir, have) do
    have
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/, &1)))
    |> Enum.filter(&Git.exists?(git_dir, &1 <> "^{commit}"))
    |> Enum.uniq()
  end

  # Thin when there is something to be thin against; a bundle git would call
  # empty (every ref already held) is sent whole.
  defp create_seed(git_dir, refs, have, dest) do
    File.rm(dest)
    File.mkdir_p!(Path.dirname(dest))

    with [_ | _] <- have,
         {:ok, _} <- Git.run(["bundle", "create", dest] ++ refs ++ Enum.map(have, &("^" <> &1)), git_dir: git_dir) do
      {:ok, true}
    else
      _ ->
        File.rm(dest)

        case Git.run(["bundle", "create", dest] ++ refs, git_dir: git_dir) do
          {:ok, _} -> {:ok, false}
          {:error, {:git, _, out}} -> {:error, {:bundle_failed, out}}
        end
    end
  end

  defp seed_size(path, cap) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= cap -> {:ok, size}
      {:ok, %{size: size}} -> File.rm(path) && {:error, {:too_large, size}}
      {:error, reason} -> {:error, {:bundle_failed, reason}}
    end
  end

  defp list_heads(git_dir, bundle) do
    case Git.run(["bundle", "list-heads", bundle], git_dir: git_dir) do
      {:ok, out} ->
        heads =
          for line <- String.split(out, "\n", trim: true),
              [sha, ref] <- [String.split(line, " ", parts: 2)],
              do: {sha, ref}

        {:ok, heads}

      {:error, {:git, _, out}} ->
        {:error, {:bad_bundle, out}}
    end
  end

  # ---- ingest ------------------------------------------------------------------------

  @doc """
  Ingest an uploaded checkout bundle through the quarantine (see the moduledoc).

  `{:ok, %{head, snapshot, status_hash, filtered, checkpoint_ref}}`, or
  `{:error, reason}` with the home clone untouched: `{:too_large, bytes}`,
  `{:prerequisites_missing, out}`, `{:bad_bundle, out}`, `{:ref_not_allowed, ref}`,
  `:no_snapshot`, `{:fsck, out}`, `{:too_many_objects, n}`,
  `:snapshot_not_on_branch`, `{:veto, kind, detail}`.
  """
  @spec ingest(Path.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def ingest(bundle, %{run: run, home: home, scratch: scratch} = ctx) do
    q = Path.join(scratch, "quarantine-#{run}-#{System.unique_integer([:positive])}.git")

    try do
      with :ok <- check_size(bundle, Map.get(ctx, :max_bytes) || max_bytes()),
           {:ok, home_git} <- Git.git_dir(home),
           :ok <- init_quarantine(q, home_git),
           :ok <- verify(q, bundle),
           {:ok, heads} <- list_heads(q, bundle),
           {:ok, refs} <- allow(heads, ctx),
           :ok <- fetch(q, bundle, refs),
           :ok <- bound(q, Map.get(ctx, :max_objects, @default_max_objects)),
           {:ok, shape} <- shape(q, home_git, ctx),
           {:ok, shape} <- filter(q, home_git, shape, ctx),
           :ok <- check_vetoes(q, shape, ctx) do
        handoff(q, home, home_git, shape, ctx)
      end
    after
      File.rm_rf(q)
    end
  end

  defp check_size(bundle, cap) do
    case File.stat(bundle) do
      {:ok, %{size: size}} when size > cap -> {:error, {:too_large, size}}
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:bad_bundle, reason}}
    end
  end

  # The quarantine borrows the home clone's objects (read-only, through
  # alternates) so a thin bundle's prerequisites resolve without a copy; the
  # incoming objects land in the quarantine's own store.
  defp init_quarantine(q, home_git) do
    File.mkdir_p!(Path.dirname(q))

    with {:ok, _} <- Git.run(["init", "-q", "--bare", q]),
         :ok <- config(q, "fetch.fsckObjects", "true"),
         :ok <- config(q, "transfer.fsckObjects", "true"),
         :ok <- config(q, "core.hooksPath", "/dev/null"),
         :ok <- config(q, "core.fsmonitor", "false"),
         :ok <- config(q, "gc.auto", "0") do
      File.write(Path.join(q, "objects/info/alternates"), Path.join(home_git, "objects") <> "\n")
    end
  end

  defp config(q, key, value) do
    with {:ok, _} <- Git.run(["config", key, value], git_dir: q), do: :ok
  end

  defp verify(q, bundle) do
    case Git.run(["bundle", "verify", bundle], git_dir: q) do
      {:ok, _} -> :ok
      {:error, {:git, _, out}} -> verify_error(out)
    end
  end

  defp verify_error(out) do
    if out =~ "prerequisite",
      do: {:error, {:prerequisites_missing, out}},
      else: {:error, {:bad_bundle, out}}
  end

  defp allow(heads, %{run: run, branch: branch, base: base}) do
    branch_ref = "refs/heads/" <> branch
    snapshot = snapshot_ref(run)
    allowed = [branch_ref, snapshot, "refs/remotes/origin/" <> base]

    case Enum.find(heads, fn {_sha, ref} -> ref not in allowed end) do
      {_sha, ref} ->
        {:error, {:ref_not_allowed, ref}}

      nil ->
        refs = Enum.map(heads, &elem(&1, 1))
        if snapshot in refs, do: {:ok, refs}, else: {:error, :no_snapshot}
    end
  end

  defp fetch(q, bundle, refs) do
    specs = Enum.map(refs, &"+#{&1}:#{&1}")

    case Git.run(["fetch", "-q", "--no-tags", bundle] ++ specs, git_dir: q) do
      {:ok, _} -> :ok
      {:error, {:git, _, out}} -> fetch_error(out)
    end
  end

  defp fetch_error(out) do
    if out =~ ~r/fsck|hasDotgit|\.git|index-pack died/i,
      do: {:error, {:fsck, out}},
      else: {:error, {:bad_bundle, out}}
  end

  defp bound(q, max_objects) do
    with {:ok, out} <- Git.run(["count-objects", "-v"], git_dir: q) do
      stats = for line <- String.split(out, "\n"), [k, v] <- [String.split(line, ": ", parts: 2)], into: %{}, do: {k, v}
      count = Enum.sum(for key <- ["count", "in-pack"], do: String.to_integer(stats[key] || "0"))
      if count > max_objects, do: {:error, {:too_many_objects, count}}, else: :ok
    end
  end

  # The snapshot must be a child of the run tip (the branch ref in the bundle, or,
  # when the bundle omits it because it is a prerequisite, a commit the home clone
  # already has).
  defp shape(q, home_git, %{run: run, branch: branch}) do
    snap = Git.rev_parse(q, snapshot_ref(run))
    parent = snap && Git.rev_parse(q, snap <> "^")
    branch_tip = Git.rev_parse(q, "refs/heads/" <> branch)

    cond do
      is_nil(parent) -> {:error, :snapshot_not_on_branch}
      branch_tip && branch_tip != parent -> {:error, :snapshot_not_on_branch}
      is_nil(branch_tip) and not Git.exists?(home_git, parent <> "^{commit}") -> {:error, :snapshot_not_on_branch}
      true -> {:ok, %{tip: parent, snapshot: snap, filtered: []}}
    end
  end

  # The trusted reference for "content the primary already has": the base
  # branch in the home clone.
  defp trusted_entries(home_git, %{base: base}) do
    rev =
      Enum.find_value(["refs/remotes/origin/" <> base, "refs/heads/" <> base], &Git.rev_parse(home_git, &1))

    Inspect.entries(home_git, rev)
  end

  defp filter(q, home_git, shape, ctx) do
    with {:ok, entries} <- Inspect.entries(q, shape.snapshot),
         {:ok, trusted} <- trusted_entries(home_git, ctx) do
      case Inspect.denied(entries, trusted, Map.get(ctx, :seeded_paths, [])) do
        [] -> {:ok, shape |> Map.put(:entries, entries) |> Map.put(:trusted, trusted)}
        denied -> rewrite(q, shape, ctx, entries, denied, trusted)
      end
    end
  end

  # A snapshot rewritten without the denied paths: same parent, new tree.
  defp rewrite(q, shape, %{run: run}, entries, denied, trusted) do
    index = Path.join(q, "filter-index")
    work = Path.join(q, "filter-work")
    File.mkdir_p!(work)
    env = [{"GIT_INDEX_FILE", index}]

    with {:ok, _} <- Git.run(["read-tree", shape.snapshot], git_dir: q, env: env),
         :ok <- remove_from_index(q, work, env, denied),
         {:ok, tree} <- Git.run(["write-tree"], git_dir: q, env: env),
         {:ok, snap} <-
           Git.run(["commit-tree", "-p", shape.tip, "-m", "arbiter snapshot (filtered)", tree], git_dir: q),
         {:ok, _} <- Git.run(["update-ref", snapshot_ref(run), snap], git_dir: q) do
      File.rm(index)

      {:ok,
       %{shape | snapshot: snap, filtered: denied}
       |> Map.put(:entries, Map.drop(entries, denied))
       |> Map.put(:trusted, trusted)}
    end
  end

  defp remove_from_index(q, work, env, denied) do
    denied
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Git.run(["update-index", "--force-remove", "--"] ++ chunk, git_dir: q, work_tree: work, env: env) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Both trees are judged: the tip (what the run committed) against the primary's
  # base, the snapshot (what it left uncommitted) against the tip.
  defp check_vetoes(q, %{tip: tip, entries: entries, trusted: trusted}, ctx) do
    with {:ok, tip_entries} <- Inspect.entries(q, tip),
         :ok <- Inspect.veto(q, tip_entries, trusted),
         :ok <- Inspect.veto(q, entries, tip_entries) do
      cap = Map.get(ctx, :max_untracked_bytes) || max_untracked_bytes()
      bytes = Inspect.added_bytes(entries, tip_entries)

      if bytes > cap,
        do: {:error, {:veto, :untracked_size, "#{bytes} bytes untracked, cap #{cap}"}},
        else: :ok
    end
  end

  defp handoff(q, home, home_git, %{tip: tip, snapshot: snap, filtered: filtered}, %{run: run, branch: branch}) do
    checkpoint = checkpoint_ref(run)

    with {:ok, _} <-
           Git.run(["fetch", "-q", "--no-tags", q, "+#{snapshot_ref(run)}:#{checkpoint}"],
             git_dir: home_git,
             work_tree: home
           ),
         {:ok, status_hash} <- apply_state(home, home_git, branch, tip, snap) do
      {:ok, %{head: tip, snapshot: snap, status_hash: status_hash, filtered: filtered, checkpoint_ref: checkpoint}}
    end
  end

  # Force the branch to `tip` and make the work tree and index `snap`, then the
  # index `tip`, so everything past the tip reads as uncommitted.
  defp apply_state(home, home_git, branch, tip, snap) do
    opts = [git_dir: home_git, work_tree: home]
    branch_ref = "refs/heads/" <> branch

    with {:ok, head} <- Git.run(["symbolic-ref", "-q", "HEAD"], opts),
         true <- head == branch_ref or {:error, {:home_not_on_branch, head}},
         {:ok, _} <- Git.run(["update-ref", branch_ref, tip], opts),
         {:ok, _} <- Git.run(["read-tree", "-u", "--reset", snap], opts),
         {:ok, _} <- Git.run(["reset", "-q", "--mixed", tip], opts),
         {:ok, status} <- Git.run(["status", "--porcelain"], opts) do
      {:ok, :crypto.hash(:sha256, status) |> Base.encode16(case: :lower)}
    else
      {:error, {:git, _, out}} -> {:error, {:handoff_failed, out}}
      {:error, _} = error -> error
    end
  end

  # ---- restore -----------------------------------------------------------------------

  @doc """
  Re-apply the run's last checkpoint to the home clone: the branch at the
  checkpoint's parent, the work tree at the checkpointed state, uncommitted work
  uncommitted. `{:ok, %{head, snapshot, status_hash}}`, or `{:error, :no_checkpoint}`.
  """
  @spec restore(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore(home, run, branch) do
    with {:ok, home_git} <- Git.git_dir(home),
         snap when is_binary(snap) <- Git.rev_parse(home_git, checkpoint_ref(run)) || {:error, :no_checkpoint},
         tip when is_binary(tip) <- Git.rev_parse(home_git, snap <> "^") || {:error, :no_checkpoint},
         {:ok, status_hash} <- apply_state(home, home_git, branch, tip, snap) do
      {:ok, %{head: tip, snapshot: snap, status_hash: status_hash}}
    end
  end
end
