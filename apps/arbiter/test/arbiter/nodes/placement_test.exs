defmodule Arbiter.Nodes.PlacementTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Placement

  @eligible %{
    task_id: "bd-place1",
    workspace_id: "ws-1",
    kind: :implementer,
    provider: :claude,
    layout: :private_clone,
    no_pr?: false,
    mode: :prefer_remote
  }

  defp row(name, attrs \\ []) do
    Map.merge(
      %{
        id: "node-" <> name,
        name: name,
        state: :online,
        health: :ready,
        labels: [],
        workspace_ids: [],
        live: 0,
        max: 2
      },
      Map.new(attrs)
    )
  end

  defp place(request, rows, opts \\ []) do
    Placement.place(
      Map.merge(@eligible, Map.new(request)),
      Keyword.merge([nodes: rows, remote_available?: true], opts)
    )
  end

  describe "mode/1" do
    test "defaults to local_only and reads worker.placement from a workspace config" do
      assert Placement.mode(nil) == :local_only
      assert Placement.mode(%{config: %{}}) == :local_only

      assert Placement.mode(%{config: %{"worker" => %{"placement" => "prefer_remote"}}}) ==
               :prefer_remote

      assert Placement.mode(%{config: %{"worker" => %{"placement" => "remote_only"}}}) ==
               :remote_only
    end

    test "an unknown value falls back to local_only rather than going remote" do
      assert Placement.mode(%{config: %{"worker" => %{"placement" => "everywhere"}}}) ==
               :local_only

      assert Placement.mode(%{config: %{"worker" => %{"placement" => 3}}}) == :local_only
    end
  end

  describe "eligible/1 (eligibility first: only a podman Claude run on a private clone)" do
    test "the podman-backed Claude implementer with a private clone is eligible" do
      assert Placement.eligible(@eligible) == :ok
    end

    # bd-7ays3v: these run in the container on a private clone too; bd-cgdhlu adds
    # the `review: true` dispatch (kind `:review`); bd-bg87oz the ReviewGate fix round.
    test "so are a ReviewGate reviewer and fix round, a review: true dispatch and the merge queue's fix and conflict passes" do
      for kind <- [:reviewer, :review, :fix_pass, :conflict_pass, :review_fix_round] do
        assert Placement.eligible(%{@eligible | kind: kind}) == :ok

        assert {:local_only, :not_podman} =
                 Placement.eligible(%{@eligible | kind: kind, layout: :worktree})

        assert {:local_only, :non_claude_provider} =
                 Placement.eligible(%{@eligible | kind: kind, provider: :codex})
      end
    end

    # bd-4ic681: a resume (briefing or session; `arb worker resume`, the Reconciler's
    # boot sweep, `LostResume`) is a fresh spawn of the ticket's implementer, seeded
    # from its home clone like the first one.
    test "so is a briefing or session resume, and the automatic resume paths" do
      assert Placement.eligible(%{@eligible | kind: :resume}) == :ok

      assert {:local_only, :not_podman} =
               Placement.eligible(%{@eligible | kind: :resume, layout: :worktree})

      assert {:local_only, :non_claude_provider} =
               Placement.eligible(%{@eligible | kind: :resume, provider: :codex})

      assert {:local_only, :placement_local_only} =
               Placement.eligible(%{@eligible | kind: :resume, mode: :local_only})
    end

    test "every other spawn kind stays local" do
      assert {:local_only, :follow_up} = Placement.eligible(%{@eligible | kind: :redispatch})
    end

    test "a non-Claude provider stays local" do
      for provider <- [:codex, :agy, :gemini, :grok] do
        assert {:local_only, :non_claude_provider} =
                 Placement.eligible(%{@eligible | provider: provider})
      end
    end

    test "a bwrap-jailed or unsandboxed layout stays local" do
      for layout <- [:worktree, :shared, nil] do
        assert {:local_only, :not_podman} = Placement.eligible(%{@eligible | layout: layout})
      end
    end

    test "a dispatch with no private clone (task/research) stays local" do
      assert {:local_only, :no_private_clone} = Placement.eligible(%{@eligible | no_pr?: true})
    end

    # bd-6ypj2y: a task/research ticket has no branch, but a podman Claude run of
    # one gets a read-only seeded checkout of the target tip (`inspect?`), which a
    # node can be handed. `no_pr?` (nothing to seed at all) stays the guard.
    test "a task/research run with a read-only inspect checkout is eligible on podman Claude" do
      inspect_request = Map.merge(@eligible, %{no_pr?: true, inspect?: true})
      assert Placement.eligible(inspect_request) == :ok

      assert {:local_only, :not_podman} =
               Placement.eligible(%{inspect_request | layout: :linked_worktree})

      assert {:local_only, :non_claude_provider} =
               Placement.eligible(%{inspect_request | provider: :codex})

      assert {:local_only, :placement_local_only} =
               Placement.eligible(%{inspect_request | mode: :local_only})

      assert {:local_only, :follow_up} = Placement.eligible(%{inspect_request | kind: :follow_up})
    end

    # bd-akp9ae: a podman implementer, resume, CI fix pass or conflict pass holds no
    # git credential in its container, here or on a node: the host pushes the branch
    # it collects, with the repo's scoped credential (bd-bsmkfu). Nothing is carried,
    # so no credential kind keeps it off a node.
    test "a host-pushed kind is eligible whatever its repo's scoped credential" do
      for kind <- [:implementer, :resume, :fix_pass, :conflict_pass],
          credential <- [:github_app, :deploy_key, :token] do
        request = Map.merge(@eligible, %{kind: kind, git_credential: credential})
        assert Placement.eligible(request) == :ok, "#{kind} with #{credential}"
      end
    end

    # A ReviewGate fix round on a scoped repo pushes from its own container, so the
    # credential goes where the run goes. A GitHub App's is a short-lived token minted
    # on the primary for the run: carried, so the round may be placed.
    test "a fix round, which pushes from its container, is eligible with a GitHub App" do
      request = Map.merge(@eligible, %{kind: :review_fix_round, git_credential: :github_app})
      assert Placement.eligible(request) == :ok
      assert :github_app in Placement.remote_git_credential_kinds()
    end

    # bd-21r811's reason, kept for the kinds nothing carries yet: a deploy key or a
    # static token is a long-lived secret that does not leave the primary.
    test "a fix round with a credential kind not carried to a node stays local-only" do
      for credential <- [:deploy_key, :token, :something_new] do
        request = Map.merge(@eligible, %{kind: :review_fix_round, git_credential: credential})

        assert {:local_only, :scoped_git_credential} = Placement.eligible(request),
               "#{credential}"
      end

      refute :deploy_key in Placement.remote_git_credential_kinds()
      refute :token in Placement.remote_git_credential_kinds()
    end

    # bd-3llb3y: a GitLab project token is minted per run, scoped to one project and
    # revoked when the worker exits, so it is carried like a GitHub App's, by every
    # run kind (the container holds it as the worker's API credential too).
    test "a GitLab project token is remote-carryable for every kind that carries a credential" do
      assert :gitlab_project_token in Placement.remote_git_credential_kinds()

      for kind <- [:implementer, :resume, :fix_pass, :conflict_pass, :review_fix_round] do
        request = Map.merge(@eligible, %{kind: kind, git_credential: :gitlab_project_token})
        assert Placement.eligible(request) == :ok, "#{kind}"
      end
    end

    test "a reviewer and an inspect-only run stay eligible beside a scoped credential" do
      scoped = Map.put(@eligible, :git_credential, :deploy_key)

      for kind <- [:reviewer, :review] do
        assert Placement.eligible(%{scoped | kind: kind}) == :ok
      end

      assert Placement.eligible(Map.merge(scoped, %{no_pr?: true, inspect?: true})) == :ok
    end

    test "git_credential/2 is the kind of a scoped repo entry, nil otherwise" do
      ws = fn block -> %{config: %{"git_credentials" => block}} end

      repos = %{
        "tonic" => %{"kind" => "deploy_key", "key_secret" => "K"},
        "vstim" => %{
          "kind" => "github_app",
          "app_id" => "1",
          "installation_id" => "2",
          "private_key_secret" => "P"
        }
      }

      scoped = ws.(%{"repos" => repos})
      assert Placement.git_credential(scoped, "tonic") == :deploy_key
      assert Placement.git_credential(scoped, "vstim") == :github_app
      assert Placement.git_credential(scoped, "other") == nil

      gitlab =
        ws.(%{
          "repos" => %{
            "infra" => %{"kind" => "gitlab_project_token", "parent_token_secret" => "P"}
          }
        })

      assert Placement.git_credential(gitlab, "infra") == :gitlab_project_token

      legacy = ws.(%{"legacy_operator" => true})
      assert Placement.git_credential(legacy, "tonic") == nil
      assert Placement.git_credential(%{config: %{}}, "tonic") == nil
      assert Placement.git_credential(nil, nil) == nil
    end

    test "a request with no checkout at all stays local even beside an inspect flag" do
      assert {:local_only, :no_private_clone} =
               Placement.eligible(Map.merge(@eligible, %{no_pr?: true, inspect?: false}))
    end

    # bd-373tce: uncommitted work in the home clone is not in the seed, and the
    # run's snapshot would replace it on the way back.
    test "a run whose home clone holds uncommitted work stays local" do
      assert {:local_only, :local_work} =
               Placement.eligible(Map.put(@eligible, :local_work?, true))

      assert Placement.eligible(Map.put(@eligible, :local_work?, false)) == :ok
    end

    test "a local_only workspace keeps even an eligible run local" do
      assert {:local_only, :placement_local_only} =
               Placement.eligible(%{@eligible | mode: :local_only})
    end

    test "every reason has a phrase the hold message can use" do
      for reason <- [
            :follow_up,
            :non_claude_provider,
            :not_podman,
            :no_private_clone,
            :placement_local_only,
            :local_work
          ] do
        assert is_binary(Placement.reason_phrase(reason, %{kind: :reviewer, provider: :codex}))
      end
    end
  end

  describe "constrained nodes (A3) and degraded: netpol_unenforced (A7)" do
    test "a constrained node ranks last even when it is the emptiest" do
      rows = [row("idle-but-constrained", constrained?: true), row("busy", live: 1, max: 2)]
      assert {:ok, {:node, %{name: "busy"}}} = place(%{mode: :remote_only}, rows)
    end

    test "prefer_remote skips a constrained node and runs locally when nothing else can take it" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a", constrained?: true)])
    end

    test "remote_only has no local to fall back on: a constrained node is the last resort" do
      assert {:ok, {:node, %{name: "a"}}} =
               place(%{mode: :remote_only}, [row("a", constrained?: true)])
    end

    test "a node that is not constrained is unaffected, with or without the key" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a", constrained?: false)])
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a")])
    end

    test "a netpol_unenforced node is excluded" do
      rows = [row("a", degraded: ["netpol_unenforced"])]
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, rows)
      assert {:ok, {:local, :no_node}} = place(%{}, rows)
    end

    test "the per-node allow_unenforced_network override admits it again" do
      rows = [row("a", degraded: ["netpol_unenforced"], allow_unenforced_network: true)]
      assert {:ok, {:node, %{name: "a"}}} = place(%{mode: :remote_only}, rows)
    end

    test "the override covers only netpol_unenforced, not other degradations" do
      rows = [row("a", degraded: ["something_else"], allow_unenforced_network: true)]
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows)
    end

    test "a healthy node is picked over an overridden unenforced one only by ranking, not exclusion" do
      rows = [
        row("a", degraded: ["netpol_unenforced"], allow_unenforced_network: true),
        row("b", live: 1, max: 2)
      ]

      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows)
    end
  end

  describe "place/2" do
    test "an ineligible run is placed locally without consulting the pool" do
      rows = fn -> flunk("the node pool must not be read for an ineligible run") end

      assert {:ok, {:local, {:local_only, :follow_up}}} =
               Placement.place(%{@eligible | kind: :redispatch},
                 nodes: rows,
                 remote_available?: true
               )
    end

    test "local_only (the default) is always local, even with a node free" do
      assert {:ok, {:local, {:local_only, :placement_local_only}}} =
               place(%{mode: :local_only}, [row("a")])
    end

    # bd-akp9ae: the implementer of a GitHub App repo (or any scoped repo) carries no
    # credential: the host pushes its branch, so it is placed like any other.
    test "a scoped-credential implementer is placed on a node under prefer_remote" do
      for credential <- [:github_app, :deploy_key, :token] do
        task_id = "bd-#{credential}"

        assert {:ok, {:node, %{name: "a"}}} =
                 place(%{git_credential: credential, task_id: task_id}, [row("a")])

        Placement.release(task_id)
      end
    end

    test "a deploy-key fix round goes local under prefer_remote, never to a node" do
      assert {:ok, {:local, {:local_only, :scoped_git_credential}}} =
               place(%{git_credential: :deploy_key, kind: :review_fix_round}, [row("a")])
    end

    test "a deploy-key fix round is held, not failed, under remote_only" do
      assert {:error, {:no_node_capacity, info}} =
               place(
                 %{git_credential: :deploy_key, kind: :review_fix_round, mode: :remote_only},
                 [row("a")]
               )

      assert info.reason == :scoped_git_credential
      assert info.message =~ "scoped git credential"
      assert info.message =~ "deploy_key"
    end

    test "a GitLab project token run lands on a node under prefer_remote and is not held under remote_only" do
      for kind <- [:implementer, :review_fix_round], mode <- [:prefer_remote, :remote_only] do
        task_id = "bd-gl-#{kind}-#{mode}"

        assert {:ok, {:node, %{name: "a"}}} =
                 place(
                   %{
                     git_credential: :gitlab_project_token,
                     kind: kind,
                     mode: mode,
                     task_id: task_id
                   },
                   [row("a")]
                 ),
               "#{kind} #{mode}"

        Placement.release(task_id)
      end
    end

    test "a GitHub App fix round lands on a node" do
      assert {:ok, {:node, %{name: "a"}}} =
               place(%{git_credential: :github_app, kind: :review_fix_round}, [row("a")])
    end

    test "a reviewer with a scoped credential still lands on a node" do
      assert {:ok, {:node, %{name: "a"}}} =
               place(%{git_credential: :deploy_key, kind: :reviewer}, [row("a")])
    end

    test "the seam can switch remote execution off: placement is then always local" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a")], remote_available?: false)
    end

    # bd-afcoop (RW13): `Executor.Node` exists since RW9, so nothing but `worker.placement`
    # (default local_only) keeps a run off a node. With the old default of `false`, a real
    # dispatch could never reach a node whatever the operator configured.
    test "with no seam, remote execution is available: a free node is picked" do
      assert {:ok, {:node, %{name: "a"}}} =
               Placement.place(Map.merge(@eligible, %{mode: :prefer_remote}), nodes: [row("a")])

      assert {:ok, {:local, {:local_only, :placement_local_only}}} =
               Placement.place(Map.merge(@eligible, %{mode: :local_only}), nodes: [row("a")])
    end

    test "prefer_remote picks a node with headroom" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a")])
    end

    test "prefer_remote falls back to local when no node has a free slot" do
      assert {:ok, {:local, :no_node}} = place(%{}, [row("a", live: 2, max: 2)])
    end

    test "remote_only with no capacity is {:no_node_capacity, info}" do
      assert {:error, {:no_node_capacity, info}} =
               place(%{mode: :remote_only}, [row("a", live: 2, max: 2)])

      assert info.mode == :remote_only
      assert info.task_id == "bd-place1"
      assert info.node == nil
      assert Placement.refusal_message(info) =~ "held"
    end

    test "remote_only with no nodes at all, or before RW9, is {:no_node_capacity, _}" do
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [])

      assert {:error, {:no_node_capacity, _}} =
               place(%{mode: :remote_only}, [row("a")], remote_available?: false)
    end

    # bd-cgdhlu: a reviewer is placed like any eligible run.
    test "a ReviewGate reviewer and a review dispatch: prefer_remote takes a node with headroom, else local" do
      for kind <- [:reviewer, :review] do
        assert {:ok, {:node, %{name: "a"}}} = place(%{kind: kind}, [row("a")])
        Placement.release("bd-place1")

        assert {:ok, {:local, :no_node}} =
                 place(%{kind: kind}, [row("a", live: 2, max: 2)])
      end
    end

    test "a reviewer under remote_only is held when no node has room, and placed when one has" do
      for kind <- [:reviewer, :review] do
        assert {:error, {:no_node_capacity, info}} =
                 place(%{kind: kind, mode: :remote_only}, [row("a", live: 2, max: 2)])

        assert info.mode == :remote_only

        assert {:ok, {:node, %{name: "b"}}} =
                 place(%{kind: kind, mode: :remote_only}, [row("a", live: 2, max: 2), row("b")])

        Placement.release("bd-place1")
      end
    end

    test "a reviewer in a local_only workspace, or one with no podman, never goes remote" do
      for kind <- [:reviewer, :review] do
        assert {:ok, {:local, {:local_only, :placement_local_only}}} =
                 place(%{kind: kind, mode: :local_only}, [row("a")])

        assert {:ok, {:local, {:local_only, :not_podman}}} =
                 place(%{kind: kind, layout: :linked_worktree}, [row("a")])
      end
    end

    test "remote_only still lets an ineligible run go local" do
      assert {:ok, {:local, {:local_only, :follow_up}}} =
               place(%{mode: :remote_only, kind: :redispatch}, [])
    end

    test "offline, suspect, draining, revoked and unhealthy nodes are not candidates" do
      rows =
        for {name, attrs} <- [
              {"off", state: :offline},
              {"sus", state: :suspect},
              {"drn", state: :draining},
              {"rev", state: :revoked},
              {"old", health: :outdated},
              {"inc", health: :incompatible},
              {"ahd", health: :ahead}
            ],
            do: row(name, attrs)

      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, rows)
    end

    test "a node with no known cap is not a candidate" do
      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [row("a", max: nil)])
    end

    test "a workspace pin is an allowlist: unpinned nodes take any workspace" do
      pinned = row("pinned", workspace_ids: ["other-ws"])
      open = row("open")
      mine = row("mine", workspace_ids: ["ws-1"])

      assert {:error, {:no_node_capacity, _}} = place(%{mode: :remote_only}, [pinned])
      assert {:ok, {:node, %{name: "open"}}} = place(%{}, [pinned, open])
      assert {:ok, {:node, %{name: "mine"}}} = place(%{}, [pinned, mine])
    end

    test "required labels must all be on the node" do
      rows = [row("a", labels: ["zone=a"]), row("b", labels: ["zone=a", "gpu=yes"])]
      assert {:ok, {:node, %{name: "b"}}} = place(%{labels: ["gpu=yes"]}, rows)
    end

    test "ranks by lowest live/max, then name" do
      assert {:ok, {:node, %{name: "big"}}} =
               place(%{}, [row("busy", live: 1, max: 2), row("big", live: 1, max: 4)])

      assert {:ok, {:node, %{name: "idle"}}} =
               place(%{}, [row("busy", live: 1, max: 2), row("idle", live: 0, max: 2)])

      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("b"), row("a")])
    end

    test "a placement reserves its slot until released, so a burst cannot overbook" do
      rows = [row("solo", max: 1)]
      parent = self()

      holder =
        spawn_link(fn ->
          send(parent, {:placed, place(%{task_id: "bd-first"}, rows)})

          receive do
            :release ->
              Placement.release("bd-first")
              send(parent, :released)
          end
        end)

      assert_receive {:placed, {:ok, {:node, _}}}

      assert {:error, {:no_node_capacity, _}} =
               place(%{task_id: "bd-second", mode: :remote_only}, rows)

      send(holder, :release)
      assert_receive :released
      assert {:ok, {:node, _}} = place(%{task_id: "bd-second"}, rows)
    end
  end

  describe "a self-derated node (bd-6w7usy)" do
    defp derated(name, level, attrs \\ []) do
      row(
        name,
        [
          max: 4,
          live: 1,
          offered: 1,
          derate: level,
          derate_reason: "thermal 96 °C",
          temp_c: 96.0
        ] ++ attrs
      )
    end

    test "a soft or hard derated node is not a candidate even with free slots under its cap" do
      for level <- [:soft, :hard] do
        assert {:ok, {:local, :no_node}} =
                 place(%{mode: :prefer_remote}, [derated("hot", level)])
      end
    end

    test "placement goes to a healthy node instead" do
      rows = [derated("hot", :hard), row("cool", max: 2)]
      assert {:ok, {:node, %{name: "cool"}}} = place(%{mode: :remote_only}, rows)
    end

    test "every kind of run is kept off a hard-derated node (resumes, fix passes, reviewers)" do
      for kind <- [:implementer, :resume, :fix_pass, :conflict_pass, :review_fix_round, :reviewer] do
        assert {:error, {:no_node_capacity, _}} =
                 place(%{mode: :remote_only, kind: kind}, [derated("hot", :hard)])
      end
    end

    test "the hold names the machine and what it sensed" do
      assert {:error, {:no_node_capacity, info}} =
               place(%{mode: :remote_only}, [derated("ryan-oryx-pro", :hard)])

      assert info.message =~ "held — ryan-oryx-pro thermal 96 °C"
      assert info.derated == [%{name: "ryan-oryx-pro", level: :hard, reason: "thermal 96 °C"}]
    end

    test "a hand-built row without :offered offers its cap" do
      assert {:ok, {:node, %{name: "plain"}}} = place(%{mode: :remote_only}, [row("plain")])
    end
  end

  # DC8 (design provider-dynamic-concurrency §4.4): the scheduler walk planned the
  # run on a node, and dispatch prefers it while it is still a candidate.
  describe "place/2 with a planned node (prefer:)" do
    test "the planned node goes first, over a less loaded one" do
      rows = [row("a"), row("b", live: 1)]

      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows)
      Placement.release("bd-place1")

      assert {:ok, {:node, %{name: "b"}}} = place(%{}, rows, prefer: "node-b")
    end

    test "a planned node that has filled since is passed over for the usual rank" do
      rows = [row("a"), row("b", live: 2)]
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows, prefer: "node-b")
    end

    test "a planned node the run may not use is never forced" do
      rows = [row("a"), row("b", workspace_ids: ["another-ws"])]
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, rows, prefer: "node-b")
    end

    test "a plan for the primary changes nothing: placement ranks as it always does" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [row("a")], prefer: "local")
    end
  end

  describe "caps.registries (KH13, §20.10)" do
    defp cluster(name, registries),
      do: row(name, caps: %{"image" => "registry", "registries" => registries})

    test "a run whose images live in a registry the node cannot pull from is not placed there" do
      rows = [cluster("a", ["ghcr.io/ryan/"])]

      assert {:error, {:no_node_capacity, _}} =
               place(%{mode: :remote_only, registry: "registry.gitlab.com/vstim"}, rows)

      assert {:ok, {:local, :no_node}} = place(%{registry: "registry.gitlab.com/vstim"}, rows)
    end

    test "a registry mismatch hold names the repo registry and the nodes' registries" do
      rows = [cluster("a", ["ghcr.io/ryan/"]), cluster("b", ["quay.io/x/"])]

      assert {:error, {:no_node_capacity, info}} =
               place(%{mode: :remote_only, registry: "registry.gitlab.com/vstim"}, rows)

      assert info.reason == :registry_mismatch
      assert info.repo_registry == "registry.gitlab.com/vstim"
      assert info.node_registries == ["ghcr.io/ryan/", "quay.io/x/"]
      assert info.message =~ "registry_mismatch"
      assert info.message =~ "registry.gitlab.com/vstim"
      assert info.message =~ "ghcr.io/ryan/"
      refute Placement.refusal_message(info) =~ "no node has capacity"
    end

    test "the node whose prefixes cover the registry is the candidate" do
      rows = [
        cluster("a", ["ghcr.io/ryan/"]),
        cluster("b", ["registry.gitlab.com/vstim/", "ghcr.io/ryan/"])
      ]

      assert {:ok, {:node, %{name: "b"}}} =
               place(%{mode: :remote_only, registry: "registry.gitlab.com/vstim"}, rows)

      assert {:ok, {:node, %{name: "a"}}} =
               place(%{mode: :remote_only, registry: "ghcr.io/ryan/arbiter-worker"}, rows)
    end

    test "a prefix does not cover a sibling that merely shares its leading characters" do
      rows = [cluster("a", ["ghcr.io/ryan/"])]

      assert {:error, {:no_node_capacity, _}} =
               place(%{mode: :remote_only, registry: "ghcr.io/ryan-evil"}, rows)
    end

    test "no registry on the request, or no caps.registries on the node, filters nothing" do
      assert {:ok, {:node, %{name: "a"}}} = place(%{}, [cluster("a", ["ghcr.io/ryan/"])])

      assert {:ok, {:node, %{name: "a"}}} =
               place(%{registry: "registry.gitlab.com/vstim"}, [row("a")])

      assert {:ok, {:node, %{name: "a"}}} =
               place(%{registry: "registry.gitlab.com/vstim"}, [
                 row("a", caps: %{"image" => "registry"})
               ])
    end

    test "registry_covered?/2" do
      assert Placement.registry_covered?(cluster("a", ["r.io/x/"]), "r.io/x")
      assert Placement.registry_covered?(cluster("a", ["r.io/x/"]), "r.io/x/sub")
      refute Placement.registry_covered?(cluster("a", ["r.io/x/"]), "r.io/y")
      refute Placement.registry_covered?(cluster("a", []), "r.io/y")
      assert Placement.registry_covered?(cluster("a", []), nil)
    end

    test "image_registry/2 is the repo's, else the workspace's registry" do
      ws = %{
        config: %{
          "worker" => %{
            "image" => %{"registry" => "ghcr.io/ryan"},
            "repos" => %{"vstim" => %{"image" => %{"registry" => "registry.gitlab.com/vstim"}}}
          }
        }
      }

      assert Placement.image_registry(ws, "vstim") == "registry.gitlab.com/vstim"
      assert Placement.image_registry(ws, "other") == "ghcr.io/ryan"
    end
  end
end
