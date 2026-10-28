defmodule Arbiter.Worker.DispatchNodePlacementTest do
  @moduledoc """
  RW8 (bd-3igo6h): the second admission gate in `Worker.Dispatch.dispatch/2`
  (`ensure_node_capacity/2`, after `ensure_account_capacity/2`): per-workspace
  `worker.placement`, the primary's own cap, and `{:no_node_capacity, _}`.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Nodes
  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @repo ResumeSlotFixture.repo()

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()
    ResumeSlotFixture.put_local_cap(nil)
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)
    %{ws: workspace!(), sandbox: sandbox}
  end

  defp workspace!(config \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "place-#{n}", prefix: "pl#{n}", config: config})
    ws
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- placement fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp latest_run(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(base_task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  defp dispatch(issue, opts \\ []) do
    Dispatch.dispatch(issue.id, [repo: @repo, start_driver: false] ++ opts)
  end

  describe "worker.placement unset (local_only) and no override: the hardware suggestion applies" do
    test "a dispatch under the suggestion starts a worker and keeps no reservation", %{ws: ws} do
      issue = ready!(ws, "under the suggestion")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
      assert Ash.get!(Issue, issue.id).state == :active
      # The slot reserved at the gate is released once the worker is registered.
      assert Placement.reservations() == []
    end

    test "fresh dispatches are held at the enforced default cap, DC1 (§5.1)", %{ws: ws} do
      # 2 CPUs suggest one worker.
      put_app_env(:arbiter, :local_hardware, %{cpus: 2, mem_total: 64 * 1024 * 1024 * 1024})
      assert %{cap: 1, source: :suggestion} = Arbiter.Nodes.LocalCapacity.cap()

      assert {:ok, %{worker_pid: pid}} = dispatch(ready!(ws, "first"))
      assert is_pid(pid)

      held = ready!(ws, "second")
      assert {:error, {:no_node_capacity, %{node: "local", cap: 1}}} = dispatch(held)
      assert Ash.get!(Issue, held.id).state == :queued
    end

    # DC1 (§5.1): the registry entry names the node a run was placed on, so the
    # primary's cap stops counting it.
    test "a run placed on a node carries its node_id on the registry entry", %{ws: ws} do
      issue = ready!(ws, "placed on a node")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, node: %{id: "n-placed", name: "placed"})

      assert %{node_id: "n-placed"} =
               Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid))

      refute issue.id in Arbiter.Nodes.LocalCapacity.holders()
    end

    test "a run that stays on the primary has no node_id", %{ws: ws} do
      issue = ready!(ws, "stays local")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)

      assert %{node_id: nil} =
               Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid))

      assert issue.id in Arbiter.Nodes.LocalCapacity.holders()
    end

    test "prefer_remote with no node available runs locally, as before", %{ws: _ws} do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end
  end

  # The podman-backed Claude implementer: the only run placement may send away.
  @podman [security: %{"sandbox" => %{"backend" => "podman"}}]

  describe "worker.placement: remote_only" do
    test "an eligible run is held with {:no_node_capacity, _} while nothing can run remotely" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      issue = ready!(ws, "remote only")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman)
      assert info.mode == :remote_only
      assert info.task_id == issue.id

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
    end

    test "a node whose caps.registries do not cover the repo's registry is not a candidate (KH13)" do
      ws =
        workspace!(%{
          "worker" => %{
            "placement" => "remote_only",
            "image" => %{"registry" => "registry.gitlab.com/vstim"}
          }
        })

      issue = ready!(ws, "registry not covered")

      row = %{
        id: "n-ghcr",
        name: "ghcr-only",
        state: :online,
        health: :ready,
        max: 2,
        live: 0,
        workspace_ids: [],
        labels: [],
        caps: %{"image" => "registry", "registries" => ["ghcr.io/ryan/"]}
      }

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman ++ [nodes: [row]])
      assert info.mode == :remote_only
      # refused at placement (no candidate), not after reserving the node and failing its image
      refute Map.has_key?(info, :image_error)
      assert info.nodes_known == 1
      assert Worker.whereis(issue.id) == nil
    end
  end

  # bd-akp9ae: a podman implementer holds no git credential in its container (the
  # host pushes its branch with the repo's scoped credential, bd-bsmkfu), so a scoped
  # repo's implementer is placed like any other: bd-21r811 kept it on the primary
  # for a key it never carried.
  describe "a repo with a scoped git credential" do
    setup do
      for {key, value} <- [
            worker_container_available: true,
            worker_container_network_available: true,
            worker_deps_cache: false
          ],
          do: put_app_env(:arbiter, key, value)

      :ok
    end

    defp scoped_ws!(mode, entry) do
      workspace!(%{
        "worker" => %{"placement" => mode},
        "git_credentials" => %{"repos" => %{@repo => entry}}
      })
    end

    defp app_entry do
      %{
        "kind" => "github_app",
        "app_id" => "42",
        "installation_id" => "7",
        "private_key_secret" => "APP_KEY"
      }
    end

    defp node_row do
      %{
        id: "n-scoped",
        name: "scoped-node",
        state: :online,
        health: :ready,
        max: 2,
        live: 0,
        workspace_ids: [],
        labels: [],
        caps: %{}
      }
    end

    # The agent spawn, captured: where the run went and the credential it was handed.
    defp capture_spawn do
      test = self()

      fn session_opts ->
        send(test, {:spawned, Keyword.get(session_opts, :node), session_opts[:git_credential]})
        {:ok, :captured}
      end
    end

    test "a GitHub App repo's implementer is placed on a node under prefer_remote, carrying no credential" do
      issue = ready!(scoped_ws!("prefer_remote", app_entry()), "app prefer remote")

      assert {:ok, %{worker_pid: pid}} =
               dispatch(
                 issue,
                 @podman ++
                   [nodes: [node_row()], start_claude: true, claude_start: capture_spawn()]
               )

      assert_receive {:spawned, %{id: "n-scoped"}, plan}
      # The host pushes the branch it collects (and opens the PR) with the App's
      # token, minted on the primary; the container is handed nothing to push with.
      assert %Arbiter.Worker.GitCredential{mode: :not_needed} = plan

      assert {:ok, %{material: nil, env: [], redact: []}} =
               Arbiter.Worker.GitCredential.prepare(plan, nil, self(), container?: true)

      assert %{node_id: "n-scoped"} =
               Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid))
    end

    test "a deploy-key repo's implementer is placed on a node too: the key never leaves the primary" do
      entry = %{"kind" => "deploy_key", "key_secret" => "K"}
      issue = ready!(scoped_ws!("prefer_remote", entry), "deploy key prefer remote")

      assert {:ok, %{worker_pid: _pid}} =
               dispatch(
                 issue,
                 @podman ++
                   [nodes: [node_row()], start_claude: true, claude_start: capture_spawn()]
               )

      assert_receive {:spawned, %{id: "n-scoped"}, %{mode: :not_needed}}
    end

    test "remote_only does not hold the implementer for its credential" do
      issue = ready!(scoped_ws!("remote_only", app_entry()), "scoped remote only")

      # No node is free: held for that, never for the credential.
      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman ++ [nodes: []])
      assert info.mode == :remote_only
      refute Map.get(info, :reason) == :scoped_git_credential
      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
    end
  end

  # bd-amm00p: a re-dispatch of an In-progress ticket stays on the primary only when
  # its earlier attempt got as far as the agent. A first attempt that failed in
  # prepare/publish/pull never ran anything, so placement is asked again.
  describe "a re-dispatch after a first attempt (bd-amm00p)" do
    setup do
      for {key, value} <- [
            worker_container_available: true,
            worker_container_network_available: true,
            worker_deps_cache: false
          ],
          do: put_app_env(:arbiter, key, value)

      :ok
    end

    defp redispatchable!(stop_category, extra \\ %{}) do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "redispatch #{stop_category}")
      {:ok, active} = Ash.update(issue, %{}, action: :start)

      Ash.create!(
        Arbiter.Workers.Run,
        Map.merge(
          %{
            task_id: active.id,
            workspace_id: ws.id,
            repo: @repo,
            kind: :implement,
            state: :finished,
            outcome: :failed,
            stop_category: stop_category,
            started_at: DateTime.utc_now()
          },
          extra
        )
      )

      active
    end

    defp spawn_to_test do
      test = self()

      fn session_opts ->
        send(test, {:spawned, Keyword.get(session_opts, :node)})
        {:ok, :captured}
      end
    end

    defp redispatch_opts,
      do: @podman ++ [nodes: [node_row()], start_claude: true, claude_start: spawn_to_test()]

    test "a first attempt that failed before the agent started is placed on a node again" do
      for category <- ~w(spawn_failed placement_refused container_create_failed) do
        issue = redispatchable!(category)
        assert {:ok, %{worker_pid: pid}} = dispatch(issue, redispatch_opts())
        assert_receive {:spawned, %{id: "n-scoped"}}
        ref = Process.monitor(pid)
        :ok = Worker.stop(issue.id, :normal)
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      end
    end

    test "an operator stop before the agent started is placed on a node again" do
      issue =
        redispatchable!(nil, %{outcome: :stopped, failure_reason: "operator_stop by coordinator"})

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, redispatch_opts())
      assert_receive {:spawned, %{id: "n-scoped"}}
      ref = Process.monitor(pid)
      :ok = Worker.stop(issue.id, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end

    test "an operator stop after the agent started stays on the primary" do
      issue =
        redispatchable!(nil, %{
          outcome: :stopped,
          failure_reason: "operator_stop",
          session_id: "sess-1"
        })

      assert {:ok, %{worker_pid: _pid}} = dispatch(issue, redispatch_opts())
      assert_receive {:spawned, nil}
    end

    test "a re-dispatch after an attempt that ran the agent stays on the primary" do
      issue = redispatchable!("crashed")
      assert {:ok, %{worker_pid: _pid}} = dispatch(issue, redispatch_opts())
      assert_receive {:spawned, nil}
    end

    test "a pre-agent failure with a retained primary worktree holding work stays on the primary",
         %{sandbox: sandbox} do
      issue = redispatchable!("spawn_failed")
      branch = Arbiter.Worker.BranchNamer.derive(issue)

      {:ok, path} =
        Arbiter.Worker.Worktree.create(sandbox.repo, branch, "main", layout: :private_clone)

      File.write!(Path.join(path, "dirty.txt"), "uncommitted")

      assert {:ok, %{worker_pid: _pid}} = dispatch(issue, redispatch_opts())
      assert_receive {:spawned, nil}
    end
  end

  # bd-cgdhlu: a `review: true` dispatch is a placement candidate when the review
  # may run in a container.
  describe "a review: true dispatch" do
    test "under remote_only on a podman review is held while nothing can run remotely" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      issue = ready!(ws, "review remote only")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman ++ [review: true])
      assert info.mode == :remote_only
      assert info.task_id == issue.id
      assert Worker.whereis(issue.id) == nil
      assert Placement.reservations() == []
    end

    test "under prefer_remote with the primary's cap at 0 and no node it is held, naming that" do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "review prefer remote")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman ++ [review: true])
      assert info.phrase =~ "held — local capacity 0 (no node had a free slot)"
    end

    test "without a podman review it is never a candidate: local-only, held only by the cap" do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      issue = ready!(ws, "review bwrap")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, review: true)
      assert info.phrase =~ "run is local-only:"
      refute info.phrase =~ "no node had a free slot"
    end
  end

  # K8: a registry node's image is published before the run is committed to it,
  # and a publish that times out or fails falls back by `worker.placement`.
  describe "a registry node whose image cannot be published" do
    defp registry_row do
      %{
        id: "n-registry",
        name: "registry-node",
        state: :online,
        health: :ready,
        max: 2,
        live: 0,
        workspace_ids: [],
        labels: [],
        caps: %{"image" => "registry"}
      }
    end

    defp timed_out(extra \\ []) do
      [
        nodes: [registry_row()],
        image: "localhost/arbiter-dev/x:abc",
        publish: [stub: fn _ctx -> {:error, {:timeout, 5}} end]
      ] ++
        @podman ++ extra
    end

    # bd-5u99ki: an outdated controller silently gets no work; the run says so.
    test "prefer_remote's fallback because every node is outdated is recorded on the routing decision" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, node outdated")

      row = %{
        id: "n-old",
        name: "mesaana",
        state: :online,
        health: :outdated,
        agent_version: "0.2.88",
        server_version: "0.2.90",
        max: 5,
        live: 0,
        workspace_ids: [],
        labels: [],
        caps: %{}
      }

      assert {:ok, %{worker_pid: _pid}} = dispatch(issue, @podman ++ [nodes: [row]])

      assert %{
               "placement" => %{
                 "remote_skipped" => "remote skipped: mesaana outdated (0.2.88 < 0.2.90)",
                 "fell_back_to" => "primary",
                 "mode" => "prefer_remote"
               }
             } = latest_run(issue.id).routing_decision
    end

    test "prefer_remote falls back to the primary and releases the node slot" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, image timed out")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue, timed_out())
      assert is_pid(pid)
      assert Placement.reservations() == []
    end

    # bd-1ggu6v: the fallback is visible on the run, not only in a log line.
    test "prefer_remote's fallback to the primary is recorded on the run's routing decision" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, fallback recorded")

      assert {:ok, %{worker_pid: _pid}} = dispatch(issue, timed_out())

      assert %{
               "placement" => %{
                 "image_unavailable" => unavailable,
                 "fell_back_to" => "primary",
                 "mode" => "prefer_remote"
               }
             } = latest_run(issue.id).routing_decision

      assert unavailable =~ "timeout"
    end

    # bd-1ggu6v: a dispatch parked on the publish is listed with what it waits
    # on instead of a bare, stuck-looking entry.
    test "while the publish is pending, in_flight carries a detail naming the image wait" do
      test = self()
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, publish pending")

      stub = fn _ctx ->
        send(test, {:publishing, self()})

        receive do
          :finish_publish -> {:error, {:timeout, 5}}
        end
      end

      opts = Keyword.put(timed_out(), :publish, stub: stub)
      task = Task.async(fn -> dispatch(issue, opts) end)
      assert_receive {:publishing, publisher}, 10_000

      assert %{detail: detail, started_at: %DateTime{}} =
               Enum.find(Arbiter.Board.Drain.status().in_flight, &(&1.task_id == issue.id))

      assert detail =~ "registry image"

      send(publisher, :finish_publish)
      assert {:ok, _} = Task.await(task, 30_000)

      # The wait is over: nothing says "waiting" any more.
      refute Enum.any?(
               Arbiter.Board.Drain.status().in_flight,
               &(&1.task_id == issue.id and is_binary(&1.detail) and &1.detail =~ "registry image")
             )
    end

    test "remote_only holds the card with the image error, and reserves nothing" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      issue = ready!(ws, "remote only, image timed out")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, timed_out())
      assert info.mode == :remote_only
      assert info.image_error == {:image_unavailable, {:timeout, 5}}
      assert info.message =~ "registry image"

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
      assert Placement.reservations() == []
    end

    test "prefer_remote honours the primary's own cap when it falls back" do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, image timed out, primary full")

      assert {:error, {:no_node_capacity, %{node: "local", cap: 0}}} =
               dispatch(issue, timed_out())

      assert Placement.reservations() == []
    end
  end

  describe "worker.placement: remote_only, but the run cannot go remote" do
    test "a run that is not the podman Claude implementer stays local (never refused)" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      assert {:ok, %{worker_pid: pid}} = dispatch(ready!(ws, "bwrap run"))
      assert is_pid(pid)
    end
  end

  describe "the primary's cap at 0" do
    setup do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      :ok
    end

    test "holds a dispatch with its reason, and starts it once the cap rises", %{ws: ws} do
      issue = ready!(ws, "held")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue)
      assert info.node == "local"
      assert info.cap == 0
      assert info.phrase =~ "held — local capacity 0 (run is local-only:"

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
      # A hold leaves nothing reserved behind.
      assert Placement.reservations() == []

      {:ok, 1} = Nodes.set_local_max_workers(1, nil)
      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end

    test "an eligible prefer_remote run no node can take is held with that in the reason" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, nowhere to go")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman)
      assert info.phrase =~ "held — local capacity 0 (no node had a free slot)"
    end

    test "an agy/codex implementer is held with its provider as the reason", %{ws: ws} do
      issue = ready!(ws, "codex run")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, agent_type: :codex)

      assert info.phrase ==
               "held — local capacity 0 (run is local-only: provider codex has no podman path)"

      assert Ash.get!(Issue, issue.id).state == :queued
    end

    # bd-6ypj2y: a task/research ticket has no branch, but a podman Claude run of
    # one gets a read-only seeded checkout, so it is a placement candidate. What
    # keeps the structural guard is the rest: bwrap/unsandboxed and non-Claude runs
    # stay local, and so does a dispatch that gets no checkout at all.
    defp research!(ws) do
      {:ok, created} =
        Ash.create(Issue, %{
          title: "research it",
          workspace_id: ws.id,
          issue_type: :research,
          acceptance: "- findings in notes"
        })

      {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
      issue
    end

    test "a non-podman research dispatch is held as local-only (not podman)", %{ws: ws} do
      issue = research!(ws)

      assert {:error, {:no_node_capacity, info}} = dispatch(issue)
      assert info.phrase =~ "run is local-only: sandbox is not podman"
    end

    test "a non-Claude podman task dispatch is held as local-only (provider)", %{ws: ws} do
      issue = research!(ws)

      assert {:error, {:no_node_capacity, info}} =
               dispatch(issue, @podman ++ [agent_type: :codex])

      assert info.phrase =~ "run is local-only: provider codex has no podman path"
    end

    test "a research dispatch given no checkout at all is held with that reason", %{ws: ws} do
      issue = research!(ws)

      assert {:error, {:no_node_capacity, info}} =
               dispatch(issue, @podman ++ [provision_worktree: false])

      assert info.phrase =~ "run is local-only: no checkout (provision_worktree: false)"
    end

    test "a podman Claude research dispatch is a node candidate, held while none is free" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = research!(ws)

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman)
      assert info.phrase =~ "held — local capacity 0 (no node had a free slot)"
    end

    test "force_slot goes over the cap", %{ws: ws} do
      issue = ready!(ws, "forced")
      assert {:ok, _} = dispatch(issue, force_slot: true, slot_override_actor: "test")
    end
  end

  describe "the primary's cap at N" do
    test "refuses the (N+1)th fresh dispatch and releases its reservation after each", %{ws: ws} do
      {:ok, 2} = Nodes.set_local_max_workers(2, nil)

      assert {:ok, _} = dispatch(ready!(ws, "one"))
      assert {:ok, _} = dispatch(ready!(ws, "two"))
      assert Placement.reservations() == []

      third = ready!(ws, "three")
      assert {:error, {:no_node_capacity, info}} = dispatch(third)
      assert info.cap == 2
      assert length(info.holders) == 2
      assert Ash.get!(Issue, third.id).state == :queued
    end

    # bd-b2iigy: a re-dispatch of an In-progress ticket replaces its own run, so
    # its own worker never holds it back; but other tickets filling the cap do
    # (it used to go over, and a restart put 5 runs on a cap of 2).
    test "a re-dispatch of a ticket already In progress is held while OTHER tickets fill the cap",
         %{ws: ws} do
      {:ok, 1} = Nodes.set_local_max_workers(1, nil)
      issue = ready!(ws, "active")
      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      ref = Process.monitor(pid)
      :ok = Worker.stop(issue.id, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      other = ready!(ws, "fills the slot")
      assert {:ok, %{worker_pid: other_pid}} = dispatch(other)

      assert {:error, {:no_node_capacity, info}} = dispatch(Ash.get!(Issue, issue.id))
      assert info.kind == :redispatch
      assert info.cap == 1
      assert Ash.get!(Issue, issue.id).state == :active
      assert Worker.whereis(issue.id) == nil

      other_ref = Process.monitor(other_pid)
      :ok = Worker.stop(other.id, :normal)
      assert_receive {:DOWN, ^other_ref, :process, _, _}, 5_000

      assert {:ok, _} = dispatch(Ash.get!(Issue, issue.id))
    end

    test "a re-dispatch is never held by the ticket's own previous run", %{ws: ws} do
      {:ok, 1} = Nodes.set_local_max_workers(1, nil)
      issue = ready!(ws, "active")
      assert {:ok, _} = dispatch(issue)

      assert {:ok, _} = dispatch(Ash.get!(Issue, issue.id))
    end
  end
end
