defmodule ArbiterWeb.NodesLiveTest do
  @moduledoc """
  `/nodes` and `/nodes/:id` (RW7, `docs/design/remote-workers.md` §14): the node
  list with the primary as a `local` row, per-node caps editable inline, the Add
  node flow, and drain / revoke / remove from the page.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Settings

  @operator Actor.operator("cli")
  @version "1.2.3"
  @url "https://primary.example.ts.net"

  setup do
    previous = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)
    {:ok, _} = Settings.set_nodes_public_url(@url)
    RateLimit.reset()

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
        :error -> Application.delete_env(:arbiter, :node_primary_version)
      end

      Settings.set_nodes_public_url(nil)
      Settings.set_nodes_local_max_workers(nil)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    :ok
  end

  defp enroll!(name, opts \\ []) do
    {:ok, %{token: t}} = Nodes.mint_join_token([name: name] ++ opts, @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(t)
    node
  end

  defp connect!(node, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "agent_version" => @version,
          "proto" => 1,
          "caps" => %{"backend" => "podman"},
          "capacity" => %{"suggestion" => 4},
          "runs" => []
        },
        overrides
      )

    # A stand-in channel that outlives the test process. Attaching `self()` made
    # the test's own exit a channel :DOWN, so the session wrote a `disconnected`
    # event (and the page re-read) mid sandbox teardown, dropping the connection.
    # Stop the session first, then the channel, so nothing writes on the way out.
    channel = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, %{pid: pid}} = Registry.attach(node, channel, params, tick_ms: :infinity)

    on_exit(fn ->
      Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
      Process.exit(channel, :kill)
    end)
  end

  describe "the list" do
    test "has the primary as a local row and one row per node", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-table")
      assert has_element?(view, "#node-local")
      assert has_element?(view, "#node-#{node.id}")
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "online")
      assert has_element?(view, "#node-#{node.id} [data-role=version]", @version)
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/4")
      assert has_element?(view, "#node-local [data-role=state]", "online")
    end

    test "shows suggested, override, ceiling and live/max for each row", %{conn: conn} do
      node = enroll!("capped", max_workers: 8)
      connect!(node, %{"capacity" => %{"suggestion" => 4, "ceiling" => 3}})

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#node-#{node.id} [data-role=suggested]", "4")
      assert has_element?(view, "#node-#{node.id} [data-role=ceiling]", "3")
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/3")
      assert has_element?(view, "#cap-form-#{node.id} input[name=max_workers][value='8']")
      assert has_element?(view, "#node-#{node.id} [data-role=cap-bound]")
    end

    test "an offline, a draining and a revoked node each say so", %{conn: conn} do
      cold = enroll!("cold")
      drained = enroll!("drained")
      gone = enroll!("gone")
      connect!(drained)
      {:ok, _} = Nodes.drain(drained, @operator)
      {:ok, _} = Nodes.revoke(gone, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#node-#{cold.id} [data-role=state]", "offline")
      assert has_element?(view, "#node-#{drained.id} [data-role=state]", "draining")
      assert has_element?(view, "#node-#{gone.id} [data-role=state]", "revoked")
    end

    test "the header breaks capacity down by machine, with no ceiling over the sum (DC1)", %{
      conn: conn
    } do
      Application.put_env(:arbiter, :remote_execution, true)
      on_exit(fn -> Application.delete_env(:arbiter, :remote_execution) end)

      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      connect!(enroll!("alpha", max_workers: 3))

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-capacity-summary", "local 2")
      assert has_element?(view, "#nodes-capacity-summary", "alpha 3")
      assert has_element?(view, "#nodes-capacity-summary", "5")
      refute has_element?(view, "#nodes-capacity-summary", "conductor.max_concurrent")
      refute has_element?(view, "#nodes-ceiling-warning")
    end

    test "the local row's suggestion is the primary's hardware suggestion", %{conn: conn} do
      previous = Application.fetch_env(:arbiter, :local_hardware)

      Application.put_env(:arbiter, :local_hardware, %{
        cpus: 12,
        mem_total: 31 * 1024 * 1024 * 1024
      })

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, :local_hardware, v)
          :error -> Application.delete_env(:arbiter, :local_hardware)
        end
      end)

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#node-local [data-role=suggested]", "6")
    end

    test "a local cap of 0 shows a persistent warning", %{conn: conn} do
      {:ok, 0} = Nodes.set_local_max_workers(0, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, "#nodes-local-cap-warning")
      assert has_element?(view, "#nodes-local-cap-warning", "wait")

      {:ok, _} = Nodes.set_local_max_workers(2, @operator)
      send(view.pid, :refresh)
      refute has_element?(view, "#nodes-local-cap-warning")
    end

    test "the nav links to the page", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, ~s(nav a[href="/nodes"]))
    end
  end

  describe "inline caps" do
    test "overrides a node's cap, up or down, and audits it", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-#{node.id}", %{max_workers: "2"}) |> render_submit()

      assert Nodes.get_node(node.id).max_workers == 2
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/2")
      assert [%{detail: %{"changes" => %{"max_workers" => 2}}}] = Nodes.events(kind: :updated)
    end

    test "a blank value clears the override", %{conn: conn} do
      node = enroll!("alpha", max_workers: 2)
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-#{node.id}", %{max_workers: ""}) |> render_submit()
      assert Nodes.get_node(node.id).max_workers == nil
    end

    test "the local cap can go to 0", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-local", %{max_workers: "0"}) |> render_submit()

      assert Settings.nodes_local_max_workers() == 0
      assert has_element?(view, "#nodes-local-cap-warning")
      assert [%{node_id: nil, detail: %{"node" => "local"}}] = Nodes.events(kind: :updated)
    end

    test "a node's cap cannot be 0 or junk, and nothing is written", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      for bad <- ["0", "-1", "abc", "1.5"] do
        view |> form("#cap-form-#{node.id}", %{max_workers: bad}) |> render_submit()
        assert has_element?(view, "#cap-error-#{node.id}")
      end

      assert Nodes.get_node(node.id).max_workers == nil
      assert Nodes.events(kind: :updated) == []
    end
  end

  describe "row actions" do
    test "drain and undrain", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> element("#drain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :draining
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "draining")

      view |> element("#undrain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :active
      assert [_, _] = Nodes.events(kind: :drained)

      # The session broadcasts the undrain from a cast, after the click returns;
      # let the page finish that refresh so it isn't killed mid-read at teardown.
      assert_receive {:node_draining, id, false} when id == node.id
      render(view)
    end

    test "revoke, then remove", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      refute has_element?(view, "#remove-#{node.id}")
      view |> element("#revoke-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :revoked
      assert [%{actor: "operator:dashboard"}] = Nodes.events(kind: :revoked)

      view |> element("#remove-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id) == nil
      refute has_element?(view, "#node-#{node.id}")
      assert [_] = Nodes.events(kind: :removed)
    end

    test "upgrade is offered only to a connected node that is behind", %{conn: conn} do
      old = enroll!("old")
      current = enroll!("current")
      connect!(old, %{"agent_version" => "1.0.0"})
      connect!(current)
      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#upgrade-#{old.id}")
      refute has_element?(view, "#upgrade-#{current.id}")
    end

    test "a change made elsewhere shows without a reload", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      {:ok, _} = Nodes.revoke(node, @operator)
      render(view)
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "revoked")
    end
  end

  describe "Add node" do
    test "issues a token and shows the one-liner and the token separately", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      refute has_element?(view, "#add-node-modal")

      view |> element("#add-node-button") |> render_click()
      assert has_element?(view, "#add-node-modal")

      view
      |> form("#add-node-form", %{name: "gpu-1", max_workers: "2", ttl_minutes: "30"})
      |> render_submit()

      assert has_element?(view, "#join-command", "curl")
      assert has_element?(view, "#join-command", "#{@url}/nodes/join")
      assert has_element?(view, "#join-token", "arbj_")
      refute has_element?(view, "#join-command", "arbj_")
      assert has_element?(view, "#copy-join-command")
      assert has_element?(view, "#copy-join-token")
      assert has_element?(view, "#join-countdown")
      assert has_element?(view, "#join-status", "Waiting")

      assert [%{kind: :token_minted}] = Nodes.events(kind: :token_minted)
    end

    test "flips to Connected when the node enrolls", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()
      view |> form("#add-node-form", %{name: "joiner"}) |> render_submit()

      token =
        view
        |> element("#join-token")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

      {:ok, %{node: node}} = Nodes.redeem_join_token(token)

      render(view)
      assert has_element?(view, "#join-status", "Connected")
      assert has_element?(view, "#node-#{node.id}")
    end

    test "closing the modal discards the secret", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()
      view |> form("#add-node-form", %{name: "joiner"}) |> render_submit()
      assert has_element?(view, "#join-token")

      view |> element("#add-node-close") |> render_click()
      refute has_element?(view, "#add-node-modal")
      refute has_element?(view, "#join-token")
      refute render(view) =~ "arbj_"
    end

    test "a bad name or ttl is reported and mints nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()

      view |> form("#add-node-form", %{name: "gpu box"}) |> render_submit()
      assert has_element?(view, "#add-node-error")
      view |> form("#add-node-form", %{name: "local"}) |> render_submit()
      assert has_element?(view, "#add-node-error")
      view |> form("#add-node-form", %{ttl_minutes: "0"}) |> render_submit()
      assert has_element?(view, "#add-node-error")

      assert Nodes.events(kind: :token_minted) == []
    end

    test "without nodes.public_url the button explains instead of minting", %{conn: conn} do
      {:ok, _} = Settings.set_nodes_public_url(nil)
      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-public-url-missing")
      assert has_element?(view, "#add-node-button[disabled]")
    end
  end

  # A registry and a deployed release: what a cluster install needs to name an image.
  defp install_cluster_env!(home) do
    previous = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, home)
    {:ok, _} = Settings.set_nodes_registry("registry.example.test/arbiter")

    tree = Path.join([home, "releases", "v9.9.9"])
    File.mkdir_p!(Path.join(tree, "bin"))
    File.write!(Path.join(tree, "bin/arbiter"), "#!/bin/sh\n")
    File.ln_s!(tree, Path.join(home, "current"))

    on_exit(fn ->
      Settings.set_nodes_registry(nil)

      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :data_dir, v)
        :error -> Application.delete_env(:arbiter, :data_dir)
      end
    end)
  end

  describe "Add node: Kubernetes cluster (K9)" do
    @registry "registry.example.test/arbiter"

    @cluster_form %{
      kind: "cluster",
      name: "mesaana-k3s",
      namespace: "ci-workers",
      max_workers: "3",
      ttl_minutes: "30"
    }

    @moduletag :tmp_dir

    setup %{conn: conn, tmp_dir: home} do
      install_cluster_env!(home)
      %{conn: conn}
    end

    defp open_add(conn) do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()
      view
    end

    defp pick_cluster(view),
      do: view |> form("#add-node-form", %{kind: "cluster"}) |> render_change()

    defp text_of(view, selector) do
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()
    end

    test "the modal offers Machine and Kubernetes cluster, Machine first", %{conn: conn} do
      view = open_add(conn)

      assert has_element?(view, "#add-node-kind-machine[checked]")
      assert has_element?(view, "#add-node-kind-cluster")
      refute has_element?(view, "#add-node-kind-cluster[checked]")
      refute has_element?(view, "#add-node-namespace")
    end

    test "choosing a cluster shows its fields and keeps what was typed", %{conn: conn} do
      view = open_add(conn)
      view |> form("#add-node-form", %{name: "typed-already"}) |> render_change()
      pick_cluster(view)

      assert has_element?(view, "#add-node-kind-cluster[checked]")

      for id <-
            ~w(namespace max-workers cpu memory node-selector pull-secret reach admission self-upgrade ttl) do
        assert has_element?(view, "#add-node-#{id}"), "no #add-node-#{id}"
      end

      assert has_element?(view, ~s|#add-node-name[value="typed-already"]|)
      refute has_element?(view, "#add-node-registry-missing")
    end

    test "it refuses to continue without nodes.registry and says why", %{conn: conn} do
      {:ok, _} = Settings.set_nodes_registry(nil)
      view = open_add(conn)
      pick_cluster(view)

      assert has_element?(view, "#add-node-registry-missing")
      assert has_element?(view, "#add-node-submit[disabled]")

      view |> form("#add-node-form", @cluster_form) |> render_submit()
      refute has_element?(view, "#join-token")
      assert Nodes.events(kind: :token_minted) == []
    end

    test "issues a cluster token and shows the apply command, the join-Secret command and the token",
         %{conn: conn} do
      view = open_add(conn)
      pick_cluster(view)

      view
      |> form(
        "#add-node-form",
        Map.merge(@cluster_form, %{reach: "tailscale", admission: "policy"})
      )
      |> render_submit()

      apply_command = text_of(view, "#cluster-apply-command")
      secret_command = text_of(view, "#cluster-secret-command")
      token = text_of(view, "#join-token")

      assert apply_command =~ ~s|kubectl apply -f <(curl -fsSL "#{@url}/nodes/join/k8s.yaml?|
      assert apply_command =~ "name=mesaana-k3s"
      assert apply_command =~ "namespace=ci-workers"
      assert apply_command =~ "max=3"
      assert apply_command =~ "reach=tailscale"
      assert apply_command =~ "admission=policy"

      assert secret_command ==
               "read -rs T && printf %s \"$T\" | kubectl -n ci-workers create secret generic " <>
                 "arbiter-join --from-file=token=/dev/stdin"

      assert token =~ ~r/\Aarbj_/
      refute apply_command =~ token
      refute secret_command =~ token

      assert has_element?(
               view,
               "#cluster-manifests-download[href*='/nodes/join/k8s.yaml?name=mesaana-k3s']"
             )

      assert has_element?(view, "#copy-cluster-apply-command")
      assert has_element?(view, "#copy-cluster-secret-command")
      assert has_element?(view, "#copy-join-token")
      assert has_element?(view, "#join-countdown")
      assert has_element?(view, "#join-status", "Waiting")
      refute has_element?(view, "#join-command")

      assert [%{kind: :token_minted}] = Nodes.events(kind: :token_minted)
    end

    test "the token it mints enrols a cluster node, and the modal flips to Connected",
         %{conn: conn} do
      view = open_add(conn)
      pick_cluster(view)
      view |> form("#add-node-form", @cluster_form) |> render_submit()
      token = text_of(view, "#join-token")

      assert {:error, :kind_mismatch} = Nodes.redeem_join_token(token, %{})
      {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{kind: "cluster"})
      assert node.kind == "cluster"
      assert node.name == "mesaana-k3s"
      assert node.max_workers == 3

      render(view)
      assert has_element?(view, "#join-status", "Connected")
      assert has_element?(view, "#cluster-readiness")
    end

    test "a cluster needs a name, and a bad value mints nothing", %{conn: conn} do
      view = open_add(conn)
      pick_cluster(view)

      view |> form("#add-node-form", %{@cluster_form | name: ""}) |> render_submit()
      assert has_element?(view, "#add-node-error", "name")

      view |> form("#add-node-form", %{@cluster_form | max_workers: "0"}) |> render_submit()
      assert has_element?(view, "#add-node-error")

      view
      |> form("#add-node-form", Map.put(@cluster_form, :namespace, "Bad_NS"))
      |> render_submit()

      assert has_element?(view, "#add-node-error", "namespace")
      assert Nodes.events(kind: :token_minted) == []
    end

    test "closing the modal discards the token and the commands", %{conn: conn} do
      view = open_add(conn)
      pick_cluster(view)
      view |> form("#add-node-form", @cluster_form) |> render_submit()
      assert has_element?(view, "#cluster-apply-command")

      view |> element("#add-node-close") |> render_click()
      refute has_element?(view, "#add-node-modal")
      refute render(view) =~ "arbj_"
    end

    test "the machine flow is untouched by the selector", %{conn: conn} do
      view = open_add(conn)
      view |> form("#add-node-form", %{name: "gpu-1"}) |> render_submit()

      assert has_element?(view, "#join-command", "#{@url}/nodes/join")
      refute has_element?(view, "#cluster-apply-command")
    end
  end

  describe "an outdated cluster node (K9 self-upgrade)" do
    @registry "registry.example.test/arbiter"

    @moduletag :tmp_dir

    setup %{tmp_dir: home} do
      install_cluster_env!(home)
      :ok
    end

    defp cluster_node!(name, caps) do
      {:ok, %{token: t}} = Nodes.mint_join_token([name: name, kind: "cluster"], @operator)
      {:ok, %{node: node}} = Nodes.redeem_join_token(t, %{kind: "cluster"})

      connect!(node, %{
        "kind" => "cluster",
        "agent_version" => "1.0.0",
        "caps" => Map.merge(%{"backend" => "k8s", "upgrade" => "image"}, caps)
      })

      node
    end

    test "without the RBAC the page says outdated and gives the exact command", %{conn: conn} do
      node = cluster_node!("k3s", %{"self_upgrade" => false, "namespace" => "ci-workers"})
      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")

      assert render(view) =~ "outdated"

      assert text_of(view, "#upgrade-command") ==
               "kubectl -n ci-workers set image deployment/arbiter-controller " <>
                 "controller=#{@registry}/controller:v9.9.9"

      assert has_element?(view, "#copy-upgrade-command")
    end

    test "the list points at it", %{conn: conn} do
      node = cluster_node!("k3s", %{"self_upgrade" => false})
      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, "#upgrade-help-#{node.id}")
    end

    test "a node that patches itself is not given a command to run", %{conn: conn} do
      node = cluster_node!("auto", %{"self_upgrade" => true})
      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")
      refute has_element?(view, "#upgrade-command")
      assert has_element?(view, "#upgrade-self")
    end
  end

  describe "detail" do
    test "shows the event timeline, live runs and the capacity breakdown", %{conn: conn} do
      node = enroll!("alpha", max_workers: 2)
      run_id = Ash.UUID.generate()

      connect!(node, %{
        "capacity" => %{"suggestion" => 4, "ceiling" => 3},
        "runs" => [%{"id" => run_id, "state" => "running"}]
      })

      {:ok, _} = Nodes.drain(node, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")

      assert has_element?(view, "#node-detail")
      assert has_element?(view, "#node-events li", "enrolled")
      assert has_element?(view, "#node-events li", "drained")
      assert has_element?(view, "#node-live-runs", String.slice(run_id, 0, 8))
      assert has_element?(view, "#node-capacity", "suggested")
      assert has_element?(view, "#node-capacity", "3")
    end

    test "drain, revoke and remove work from the detail page; remove returns to the list",
         %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")

      view |> element("#drain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :draining
      assert has_element?(view, "#node-events li", "drained")

      view |> element("#revoke-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :revoked

      view |> element("#remove-#{node.id}") |> render_click()
      assert_redirect(view, ~p"/nodes")
      assert Nodes.get_node(node.id) == nil
    end

    test "an unknown node goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/nodes"}}} =
               live(conn, ~p"/nodes/#{Ash.UUID.generate()}")
    end
  end
end
