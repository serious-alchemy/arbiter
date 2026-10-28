defmodule Arbiter.Nodes.Placement do
  @moduledoc """
  Where a run goes: the primary (`local`) or an enrolled node
  (`docs/design/remote-workers.md` §13, bd-aowisc §4.9). The second of
  `Worker.Dispatch`'s two admission gates, run by `ensure_node_capacity/2`
  right after `ensure_account_capacity/2` and before the ticket moves.

  ## Eligibility first

  `eligible/1` is pure and runs before any node is looked at. Only a
  **podman-backed Claude run** with a private clone is ever a candidate for a
  node (bd-aowisc §5): the implementer and a resume of it, a merge-queue fix or
  conflict pass, a ReviewGate fix round, and the two reviewers, a ReviewGate
  reviewer and a `review: true` dispatch (bd-7ays3v, bd-cgdhlu, bd-bg87oz,
  bd-4ic681), and a `task`/`research` ticket (bd-6ypj2y). A resume (briefing or session, manual or the Reconciler's and
  `Arbiter.Nodes.LostResume`'s automatic one) is a fresh spawn of the
  implementer: the node is seeded from the home clone, uncommitted work included
  (`Arbiter.Nodes.Checkout.seed_bundle/2`), and a session resume also gets the
  prior session's transcript, redacted, at the same cwd slug
  (`Arbiter.Worker.ContainerSpawn.remote_spec/3`). A reviewer reads the
  head it is handed and writes nothing back but its verdict and transcript, so
  its checkout is a read-only clone seeded through the bundle path and never
  collected; a task or research ticket's is the same. A fix round and a fix or conflict pass write commits: the node is
  seeded from the ticket's branch at its **current** `origin` head and
  `origin/<target>` at the forge tip (`Arbiter.Worker.PassPlacement`), the
  checkout comes back through the same quarantine as an implementer's, and the
  host pushes it with `--force-with-lease` pinned to the remote head seeded
  from. Everything else stays on the primary, and `Arbiter.Nodes.LocalCapacity`
  is the cap that governs it:

    * the spawn kind bound to the primary (`:follow_up`: a re-dispatch of a
      ticket already under way, whose earlier attempt reached the agent. A
      redispatch after a failure BEFORE the agent started (prepare, publish, pull,
      a node refusal) is placed like a first attempt, `Dispatch.node_kind/2`,
      bd-amm00p; a retained primary worktree with work in it is `:local_work`);
    * every non-Claude provider (`:non_claude_provider`; the podman backend is
      wired for Claude only);
    * anything not run in a podman container (`:not_podman`: bwrap-jailed or
      unsandboxed; the jail needs the primary's filesystem and keyring);
    * a dispatch handed no checkout at all (`:no_private_clone`: `provision_worktree:
      false`). A `task` or `research` ticket is *not* one on podman Claude: it gets a
      read-only seeded checkout of the target branch tip (`inspect?`, bd-6ypj2y),
      placed like a reviewer's: nothing is collected or pushed back, and only notes,
      progress and the transcript return. Off podman or Claude it is `:not_podman` /
      `:non_claude_provider` like any other run;
    * a dispatch whose home clone already holds uncommitted work
      (`:local_work`: a re-dispatch of a ticket an earlier local run left
      dirty; the seed carries commits, not the work tree, and the run's snapshot
      would replace it on the way back);
    * a workspace whose `worker.placement` is `local_only`
      (`:placement_local_only`);
    * a run whose container pushes with its repo's scoped git credential (a
      ReviewGate fix round on a scoped repo) when that credential is a deploy key
      or a static token (`:scoped_git_credential`, bd-21r811): a long-lived secret
      stays on the primary. A GitHub App's goes with the run as a short-lived,
      repo-restricted installation token (`remote_git_credential_kinds/0`,
      bd-akp9ae). Every other kind is pushed for by the host, with the repo's
      scoped credential (bd-bsmkfu), so its container carries none, wherever it
      runs: the request's `:git_credential` (`git_credential/2`) does not keep it
      here.

  The discriminator for "podman" is `GitLayout.for_policy/1`'s `:private_clone`,
  which `SecurityPolicy` merges most-restrictive-wins, so nothing a workspace,
  repo or ticket sets can loosen a run into remote.

  ## Mode

  `worker.placement` on the workspace: `local_only` (the **default**, and what
  any unreadable value means), `prefer_remote` (a node with headroom, else
  local) and `remote_only` (never local: `{:no_node_capacity, info}` and the
  card is held, not failed).

  ## Candidates

  A node is a candidate when it is online (not suspect or offline), not
  draining or revoked, healthy (`ready`), has a known cap, `live + reserved <
  cap`, its workspace pin (an allowlist; empty means any workspace) admits the
  run's workspace, and it carries every label the request asks for. They are
  ranked by lowest `live/cap`, then name, **constrained nodes last** (A3: a cluster node
  reporting `hb.capacity.constrained`, i.e. runs already `pending` on it, would only queue
  this one behind them). Under `prefer_remote` a run whose only candidates are constrained
  goes local instead (the primary's own cap still gates it); `remote_only` has no local and
  takes the constrained node as a last resort. A node reporting `degraded:
  netpol_unenforced` (A7: the cluster does not enforce NetworkPolicy, so the pod's
  deny-all is not real) is **not a candidate** unless the operator set that node's
  `allow_unenforced_network` override (`Arbiter.Nodes.update_node/3`, audited). Likewise
  `psa_unenforced` (KH4: Pod Security `restricted` is not enforced on the namespace), under the
  same override. A request that names the `:registry` its images live in (KH13, §20.10:
  `image_registry/2`) is not placed on a cluster node whose `caps.registries` does not cover
  it (`registry_covered?/2`), so a repo whose images are in the vstim GitLab registry never
  reaches a node that cannot pull from it. A node that reports no `caps.registries` (an older
  controller) and every machine node are not filtered. The cap is
  `Hello.effective_max_workers/2`:
  the operator's override or the node's own suggestion, bounded by a ceiling the
  node's owner set.

  The check and the reservation run under one lock (`:global.trans/3`, local
  node only), and the reservation lives in `#{inspect(__MODULE__)}.Registry`
  keyed by task id until `release/1` (the dispatch returns) — the same shape as
  `Arbiter.Accounts.Admission` — so a burst of placements can take no more than
  the headroom.

  ## Remote execution

  `Executor.Node` exists (RW9), so `remote_execution_available?/0` is `true` by
  default and `worker.placement` (default `local_only`) is the only switch an
  operator flips. RW8 shipped it `false` ("until RW9") and nothing flipped it
  afterwards, so a real dispatch could never reach a node; the end-to-end suite
  (`:node_agent`, bd-afcoop) is what found that. `config :arbiter, remote_execution:
  false` is the kill switch.
  """

  alias Arbiter.Nodes.Overview
  alias Arbiter.Settings
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.Image.RepoConfig

  @registry __MODULE__.Registry
  @modes [:local_only, :prefer_remote, :remote_only]
  @kinds [
    :implementer,
    :redispatch,
    :resume,
    :review,
    :reviewer,
    :fix_pass,
    :conflict_pass,
    :review_fix_round
  ]

  # The kinds that run in a container on a private clone (bd-7ays3v), and so
  # may run on a node once RW9 places them. The rest are bound to the primary.
  # `:review` is a `review: true` dispatch (bd-cgdhlu): placed on a node, its
  # checkout is a read-only private clone like a ReviewGate reviewer's.
  # `:review_fix_round` (bd-bg87oz) is a ReviewGate implementer pass: it commits
  # in the author's private clone, which is seeded to the node like any other.
  # `:resume` (bd-4ic681) re-spawns the implementer on its preserved home clone.
  @remote_kinds [
    :implementer,
    :resume,
    :review,
    :reviewer,
    :fix_pass,
    :conflict_pass,
    :review_fix_round
  ]

  # bd-akp9ae: the kinds whose container pushes for itself, and so holds the repo's
  # scoped git credential wherever it runs: a ReviewGate fix round on a scoped repo
  # (`ReviewGate`'s `fix_round_host_pushes?/4` is false for it). Every other remote
  # kind runs podman on a private clone, which the host pushes for (bd-7rxy1c,
  # bd-19skda) with the repo's scoped credential (bd-bsmkfu): its container holds
  # none, here or on a node, so there is nothing to carry.
  @self_pushing_kinds [:review_fix_round]

  # The scoped credential kinds that can go where a self-pushing run goes: a GitHub
  # App's is a short-lived installation token minted on the primary for the run,
  # restricted to the one repo, delivered through the node's per-run secret channel
  # and revoked when the run ends (`ContainerSpawn.prepare_remote/1`). A deploy key
  # or a static token is a long-lived secret that stays on the primary. A GitLab
  # project token (bd-3llb3y) is the same shape: minted per run by a primary-only parent
  # credential, one project, revoked when the run's worker exits. It is also the
  # worker's GitLab API credential, so the container of *every* run kind holds it.
  @remote_git_credential_kinds [:github_app, :gitlab_project_token]

  @type mode :: :local_only | :prefer_remote | :remote_only
  @type reason ::
          :follow_up
          | :non_claude_provider
          | :not_podman
          | :no_private_clone
          | :local_work
          | :placement_local_only
          | :scoped_git_credential
  @type request :: %{
          required(:task_id) => String.t(),
          required(:kind) => atom(),
          required(:provider) => atom() | String.t() | nil,
          required(:layout) => atom() | nil,
          required(:mode) => mode(),
          optional(:workspace_id) => String.t() | nil,
          optional(:no_pr?) => boolean(),
          optional(:inspect?) => boolean(),
          optional(:local_work?) => boolean(),
          optional(:git_credential) => GitCredential.kind() | atom() | nil,
          optional(:labels) => [String.t()],
          optional(:registry) => String.t() | nil
        }
  @type info :: %{
          required(:task_id) => String.t(),
          required(:node) => String.t() | nil,
          required(:mode) => mode(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }
  @type result ::
          {:ok, {:local, :no_node | {:node_outdated, [map()]} | {:local_only, reason()}}}
          | {:ok, {:node, map()}}
          | {:error, {:no_node_capacity, info()}}

  @doc "The placement modes, default first."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "Every spawn kind placement knows (`LocalCapacity.kinds/0` says how each is capped)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The mode a workspace asks for: `worker.placement`, defaulting to `:local_only`.
  An unknown or malformed value is `:local_only` too: a typo must not send a
  sensitive workspace's runs to a remote machine.
  """
  @spec mode(map() | nil) :: mode()
  def mode(%{config: %{"worker" => %{"placement" => value}}}), do: parse_mode(value)
  def mode(_), do: :local_only

  defp parse_mode(value) when is_binary(value) do
    Enum.find(@modes, :local_only, &(Atom.to_string(&1) == value))
  end

  defp parse_mode(value) when value in @modes, do: value
  defp parse_mode(_), do: :local_only

  @doc """
  `:ok` when `request` may be placed on a node, else `{:local_only, reason}`.
  Pure. See the moduledoc for the list.
  """
  @spec eligible(request()) :: :ok | {:local_only, reason()}
  def eligible(request) do
    cond do
      request.kind not in @remote_kinds -> {:local_only, :follow_up}
      not claude?(request.provider) -> {:local_only, :non_claude_provider}
      request.layout != :private_clone -> {:local_only, :not_podman}
      no_checkout?(request) -> {:local_only, :no_private_clone}
      Map.get(request, :local_work?, false) -> {:local_only, :local_work}
      request.mode == :local_only -> {:local_only, :placement_local_only}
      carries_uncarried_credential?(request) -> {:local_only, :scoped_git_credential}
      true -> :ok
    end
  end

  # bd-21r811, bd-akp9ae: a run whose container pushes with the repo's scoped git
  # credential takes it to the node, which only a GitHub App's short-lived token
  # may do; a deploy key or a static token keeps the run on the primary (and
  # `ClaudeSession` refuses one on a node all the same: `git_credential_unsupported`).
  # A host-pushed kind, a reviewer and an inspect-only run carry nothing.
  defp carries_uncarried_credential?(request) do
    case Map.get(request, :git_credential) do
      nil ->
        false

      kind ->
        request.kind in @self_pushing_kinds and not Map.get(request, :inspect?, false) and
          kind not in @remote_git_credential_kinds
    end
  end

  @doc """
  The scoped git credential kinds a run that pushes from its container may take to
  a node (`[:github_app, :gitlab_project_token]`: a short-lived token minted per run on
  the primary, restricted to one repo).
  """
  @spec remote_git_credential_kinds() :: [GitCredential.kind()]
  def remote_git_credential_kinds, do: @remote_git_credential_kinds

  @doc """
  The kind of the scoped `GitCredential` an implementer of `repo` in `workspace`
  would push with (`:deploy_key`, `:token` or `:github_app`), or `nil` for a repo
  with none (legacy, unconfigured). What callers put in a request's
  `:git_credential`; `eligible/1` decides whether the run's kind carries it.
  """
  @spec git_credential(map() | nil, String.t() | nil) :: GitCredential.kind() | nil
  def git_credential(workspace, repo) do
    case GitCredential.plan(workspace, repo, role: :implementer) do
      {:ok, %GitCredential{mode: :scoped, entry: %{kind: kind}}} -> kind
      _ -> nil
    end
  end

  # A clone-less dispatch (task/research) is local unless it is marked `inspect?`:
  # a podman run that is handed a read-only seeded checkout of the target tip, which
  # a node can be given too (bd-6ypj2y). Any other kind of "no checkout" (an explicit
  # `provision_worktree: false`) stays the structural guard.
  defp no_checkout?(request),
    do: Map.get(request, :no_pr?, false) and not Map.get(request, :inspect?, false)

  defp claude?(provider), do: to_string(provider) == "claude"

  @doc "Why a run is local-only, as a phrase for a hold message."
  @spec reason_phrase(reason(), map()) :: String.t()
  def reason_phrase(:follow_up, %{kind: kind}),
    do: "#{kind |> to_string() |> String.replace("_", " ")} runs stay on the primary"

  def reason_phrase(:follow_up, _), do: "follow-up runs stay on the primary"

  def reason_phrase(:non_claude_provider, %{provider: provider}),
    do: "provider #{provider} has no podman path"

  def reason_phrase(:non_claude_provider, _), do: "only Claude has a podman path"

  def reason_phrase(:not_podman, _),
    do: "sandbox is not podman (bwrap-jailed or unsandboxed)"

  def reason_phrase(:no_private_clone, _), do: "no checkout (provision_worktree: false)"

  def reason_phrase(:local_work, _),
    do: "its checkout already holds uncommitted work on the primary"

  def reason_phrase(:placement_local_only, _), do: "workspace worker.placement is local_only"

  def reason_phrase(:scoped_git_credential, _),
    do:
      "it pushes with its repo's scoped git credential, a deploy key or token that cannot " <>
        "be carried to a node (only a GitHub App's or GitLab project token, minted per run, can)"

  @doc """
  True when placement may return a node (`Executor.Node` exists since RW9, so the
  default is `true`; `config :arbiter, remote_execution: false` turns it off).
  """
  @spec remote_execution_available?() :: boolean()
  def remote_execution_available?, do: Application.get_env(:arbiter, :remote_execution, true)

  @doc """
  Place `request`. Options: `:nodes` (rows, or a 0-arity function returning them;
  default `Arbiter.Nodes.Overview.node_rows/0`), `:remote_available?` (a
  seam over `remote_execution_available?/0`) and `:prefer` (the node id the
  scheduler walk planned the run on, DC8: ranked first while it is a candidate).

    * `{:ok, {:local, why}}` — run on the primary. `why` is `:no_node` (an
      eligible run no node could take, under `prefer_remote`) or
      `{:local_only, reason}`; nothing is reserved here (the primary's own cap
      is `Arbiter.Nodes.LocalCapacity`'s).
    * `{:ok, {:node, row}}` — a slot on `row` is reserved for the calling
      process under `request.task_id`.
    * `{:error, {:no_node_capacity, info}}` — `remote_only` and nothing can take it.
  """
  @spec place(request(), keyword()) :: result()
  def place(request, opts \\ []) do
    case eligible(request) do
      {:local_only, :scoped_git_credential} when request.mode == :remote_only ->
        {:error, {:no_node_capacity, scoped_credential_hold(request)}}

      {:local_only, _reason} = why ->
        {:ok, {:local, why}}

      :ok ->
        if Keyword.get_lazy(opts, :remote_available?, &remote_execution_available?/0),
          do: pick(request, opts),
          else: none(request, [])
    end
  end

  defp scoped_credential_hold(request) do
    phrase =
      "held — #{request.task_id} pushes with a scoped git credential " <>
        "(#{Map.get(request, :git_credential)}), which cannot be carried to a node " <>
        "(only a GitHub App's or GitLab project token, minted per run, can)"

    %{
      task_id: request.task_id,
      node: nil,
      mode: :remote_only,
      reason: :scoped_git_credential,
      message:
        phrase <>
          ", and worker.placement is remote_only. Run it under prefer_remote, give the repo " <>
          "a github_app or gitlab_project_token credential, or put the repo on legacy_operator."
    }
  end

  defp pick(request, opts) do
    :global.trans(
      {{__MODULE__, :place}, self()},
      fn ->
        rows = rows(opts)
        reserved = reserved_counts()
        candidates = Enum.filter(rows, &candidate?(&1, request, reserved))

        case candidates |> rank(reserved) |> prefer(Keyword.get(opts, :prefer)) do
          [%{constrained?: true} | _] when request.mode == :prefer_remote ->
            none(request, rows)

          [row | _] ->
            reserve(request.task_id, row.id)
            {:ok, {:node, row}}

          [] ->
            none(request, rows)
        end
      end,
      [node()]
    )
  end

  defp none(%{mode: :remote_only} = request, rows) do
    case registry_mismatch(request, rows) do
      nil -> none_full(request, rows)
      mismatch -> {:error, {:no_node_capacity, mismatch}}
    end
  end

  # Under `prefer_remote` the run goes local; when an online node was passed over only because
  # its agent is older than this server, that is the reason, not "no node had a free slot".
  defp none(%{mode: :prefer_remote}, rows) do
    case outdated_skipped(rows) do
      [] -> {:ok, {:local, :no_node}}
      skipped -> {:ok, {:local, {:node_outdated, skipped}}}
    end
  end

  defp none(_request, _rows), do: {:ok, {:local, :no_node}}

  defp outdated_skipped(rows) do
    for row <- rows, row.state == :online, row.health == :outdated do
      %{
        name: Map.get(row, :name) || row.id,
        version: Map.get(row, :agent_version),
        server_version: Map.get(row, :server_version)
      }
    end
  end

  @doc """
  The one-line account of nodes skipped as outdated, for the run's placement record, the
  board and the hold phrase: `remote skipped: mesaana outdated (0.2.88 < 0.2.90)`.
  """
  @spec skipped_phrase([
          %{name: String.t(), version: String.t() | nil, server_version: String.t() | nil}
        ]) ::
          String.t()
  def skipped_phrase(skipped) do
    "remote skipped: " <>
      Enum.map_join(skipped, ", ", fn s ->
        "#{s.name} outdated (#{s.version || "?"} < #{s.server_version || "?"})"
      end)
  end

  # The hold when the registry check is what excluded every node: some online node
  # advertises `caps.registries`, and none of those prefixes covers the request's registry.
  defp registry_mismatch(request, rows) do
    registry = Map.get(request, :registry)

    advertised =
      for row <- rows,
          row.state == :online,
          list = get_in(Map.get(row, :caps) || %{}, ["registries"]),
          is_list(list),
          do: list

    if is_binary(registry) and registry != "" and advertised != [] and
         not Enum.any?(rows, &(&1.state == :online and registry_covered?(&1, registry))) do
      node_registries = advertised |> List.flatten() |> Enum.uniq()

      %{
        task_id: request.task_id,
        node: nil,
        mode: :remote_only,
        reason: :registry_mismatch,
        repo_registry: registry,
        node_registries: node_registries,
        nodes_known: length(rows),
        message:
          "held — registry_mismatch{repo_registry=#{registry}, node_registries=" <>
            "[#{Enum.join(node_registries, ", ")}]}: #{request.task_id}'s images live in a " <>
            "registry no node can pull from. Add its prefix to a node's registries, or point " <>
            "the repo's image.registry at one they cover."
      }
    end
  end

  defp none_full(request, rows) do
    info = %{
      task_id: request.task_id,
      node: nil,
      mode: :remote_only,
      nodes_known: length(rows),
      derated: derated(rows)
    }

    {:error, {:no_node_capacity, Map.put(info, :message, refusal_message(info))}}
  end

  # bd-6w7usy: the online nodes that have derated themselves (thermal or memory pressure),
  # for the hold: "held — ryan-oryx-pro thermal 96 °C".
  defp derated(rows) do
    for row <- rows,
        row.state == :online,
        level = Map.get(row, :derate, :none),
        level != :none do
      %{name: Map.get(row, :name) || row.id, level: level, reason: Map.get(row, :derate_reason)}
    end
  end

  defp rows(opts) do
    case Keyword.get(opts, :nodes) do
      rows when is_list(rows) -> rows
      fun when is_function(fun, 0) -> fun.()
      nil -> Overview.node_rows()
    end
  end

  defp candidate?(row, request, reserved) do
    row.state == :online and
      row.health == :ready and
      is_integer(row.max) and row.max > 0 and
      row.live + Map.get(reserved, row.id, 0) < Arbiter.Nodes.Capacity.offered(row) and
      network_enforced?(row) and
      pin_allows?(Map.get(row, :workspace_ids, []), Map.get(request, :workspace_id)) and
      labels_match?(Map.get(row, :labels, []), Map.get(request, :labels, [])) and
      registry_covered?(row, Map.get(request, :registry))
  end

  @doc """
  KH13: can `row` pull images from `registry` (the repo's registry reference, e.g.
  `registry.gitlab.com/vstim`)? True without a registry to check, for a node that does not
  advertise `caps.registries` (a machine node builds from a plan; an older controller
  predates the cap), and for a cluster node when one of its prefixes (each ending in `/`)
  covers `registry`.
  """
  @spec registry_covered?(map(), String.t() | nil) :: boolean()
  def registry_covered?(row, registry) when is_binary(registry) and registry != "" do
    case get_in(Map.get(row, :caps) || %{}, ["registries"]) do
      prefixes when is_list(prefixes) ->
        Enum.any?(prefixes, &(is_binary(&1) and String.starts_with?(registry <> "/", &1)))

      _ ->
        true
    end
  end

  def registry_covered?(_row, _registry), do: true

  @doc """
  The registry reference the images of `repo` in `workspace` live in (KH12's resolution:
  the repo's `image.registry`, else the workspace's, else the install's `nodes.registry`),
  or `nil` when none is configured or it cannot be read. What callers put in a request's
  `:registry`.
  """
  @spec image_registry(term(), String.t() | nil) :: String.t() | nil
  def image_registry(workspace, repo) do
    case RepoConfig.resolve(workspace, repo) do
      %{registry: registry} when is_binary(registry) -> registry
      _ -> Settings.nodes_registry()
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  A7/KH4: false for a row reporting `degraded: netpol_unenforced` or `psa_unenforced` whose
  operator has not set `allow_unenforced_network`. Every other row (machine nodes, healthy clusters) is true.
  """
  @spec network_enforced?(map()) :: boolean()
  def network_enforced?(row) do
    Enum.all?(
      ~w(netpol_unenforced psa_unenforced),
      &(&1 not in List.wrap(Map.get(row, :degraded)))
    ) or
      Map.get(row, :allow_unenforced_network) == true
  end

  defp pin_allows?([], _workspace_id), do: true
  defp pin_allows?(pins, workspace_id), do: workspace_id in pins

  defp labels_match?(have, want), do: Enum.all?(want, &(&1 in have))

  defp rank(candidates, reserved) do
    Enum.sort_by(candidates, fn row ->
      {Map.get(row, :constrained?, false), (row.live + Map.get(reserved, row.id, 0)) / row.max,
       row.name}
    end)
  end

  # DC8 (`docs/design/provider-dynamic-concurrency.md` §4.4): the node the
  # scheduler walk planned the run on goes first while it is still a candidate.
  # A plan for the primary, or for a node that filled since, changes nothing.
  defp prefer(ranked, node_id) when is_binary(node_id) do
    case Enum.split_with(ranked, &(&1.id == node_id)) do
      {[planned], rest} -> [planned | rest]
      _ -> ranked
    end
  end

  defp prefer(ranked, _node_id), do: ranked

  @doc """
  The operator-facing refusal for `{:error, {:no_node_capacity, info}}` — one
  source of truth for MCP, the REST API (and so the CLI) and the dashboard. It
  covers both shapes of that error: no node free (`info.node == nil`) and the
  primary's own cap (`Arbiter.Nodes.LocalCapacity`, `info.node == "local"`).
  """
  @spec refusal_message(map()) :: String.t()
  def refusal_message(%{message: message}) when is_binary(message), do: message

  def refusal_message(%{task_id: task_id, mode: mode, derated: [_ | _] = derated} = info) do
    "held — #{Enum.map_join(derated, ", ", &"#{&1.name} #{&1.reason || "derated"}")} " <>
      "(#{task_id}: worker.placement is #{mode}; #{Map.get(info, :nodes_known, 0)} node(s) known, " <>
      "the derated one offers no new slots until its readings stay clear; running workers " <>
      "are not stopped)."
  end

  def refusal_message(%{task_id: task_id, mode: mode} = info) do
    "held — no node has capacity for #{task_id} (worker.placement is #{mode}; " <>
      "#{Map.get(info, :nodes_known, 0)} node(s) known). It starts when a node " <>
      "frees a slot, or when placement allows the primary."
  end

  @doc """
  The hold for a `remote_only` run whose node image could not be published
  (K8: `Image.Publisher.fallback/2`'s `{:hold, reason}`): the same
  `{:no_node_capacity, info}` shape as a full fleet, so every caller already
  holds the card and retries.
  """
  @spec image_hold(request(), term()) :: info()
  def image_hold(request, reason) do
    %{
      task_id: request.task_id,
      node: nil,
      mode: :remote_only,
      nodes_known: 1,
      image_error: reason,
      message:
        "held — the registry image for #{request.task_id} is not available " <>
          "(#{inspect(reason)}); worker.placement is remote_only, so it does not run on " <>
          "the primary. It starts when the image publishes."
    }
  end

  # ---- reservations ----------------------------------------------------------

  @doc """
  Drop the calling process's reservation for `task_id` (a node slot or a slot of
  the primary's cap). A no-op when it holds none.
  """
  @spec release(String.t()) :: :ok
  def release(task_id) when is_binary(task_id) do
    Registry.unregister(@registry, task_id)
  rescue
    _ -> :ok
  end

  @doc false
  @spec reserve(String.t(), String.t()) :: :ok
  def reserve(task_id, where) do
    case Registry.register(@registry, task_id, %{node: where}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc "Every live reservation as `%{task_id:, node:, pid:}`; `node` is a node id or `\"local\"`."
  @spec reservations() :: [%{task_id: String.t(), node: String.t(), pid: pid()}]
  def reservations do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn {task_id, pid, %{node: node}} ->
      if Process.alive?(pid), do: [%{task_id: task_id, node: node, pid: pid}], else: []
    end)
  rescue
    _ -> []
  end

  defp reserved_counts do
    reservations() |> Enum.frequencies_by(& &1.node)
  end
end
