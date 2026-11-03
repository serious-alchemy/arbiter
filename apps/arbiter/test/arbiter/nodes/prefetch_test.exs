defmodule Arbiter.Nodes.PrefetchTest do
  @moduledoc """
  SI7 (`docs/design/remote-workers.md` §21.2.4, §21.9): after a publish the primary sends
  `image.prefetch` to the machine nodes that could take the repo's runs, each with a pull
  credential it may hold, and to no node that already holds the digest.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PullAuth
  alias Arbiter.Nodes.Prefetch

  @ref "registry.example.com/arbiter/vstim/worker@sha256:" <> String.duplicate("a", 64)
  @auth %PullAuth{registry: "registry.example.com", username: "pull", password: "s3cret"}

  defp row(name, attrs \\ []) do
    Map.merge(
      %{
        id: "node-" <> name,
        name: name,
        kind: :machine,
        state: :online,
        health: :ready,
        draining?: false,
        caps: %{"image_prefetch" => true},
        workspace_ids: [],
        images: nil
      },
      Map.new(attrs)
    )
  end

  defp run(rows, extra \\ []) do
    test = self()

    opts =
      [
        nodes: rows,
        send_fun: fn id, payload ->
          send(test, {:prefetch, id, payload})
          :ok
        end,
        credential_fun: fn _ws, _repo, _row ->
          {:ok, %{auth: @auth, level: :repo, insecure?: false}}
        end
      ]
      |> Keyword.merge(extra)

    Prefetch.run(
      %{workspace: %{id: "ws-1"}, repo: "vstim"},
      %{ref: @ref, cli_set: "abcd1234"},
      opts
    )
  end

  test "sends the ref, cli set and pull credential to each ready machine node" do
    assert [{"node-a", :ok}, {"node-b", :ok}] = run([row("a"), row("b")])

    assert_received {:prefetch, "node-a", payload}

    assert payload == %{
             "ref" => @ref,
             "insecure" => false,
             "cli_set" => "abcd1234",
             "pull_auth" => @auth
           }

    assert_received {:prefetch, "node-b", _}
  end

  test "skips nodes that cannot or need not pull" do
    rows = [
      row("warm", images: %{"digests" => [@ref]}),
      row("offline", state: :offline),
      row("outdated", health: :outdated),
      row("draining", draining?: true),
      row("old-agent", caps: %{}),
      row("cluster", kind: :cluster),
      row("pinned", workspace_ids: ["ws-other"]),
      row("cold")
    ]

    assert [{"node-cold", :ok}] = run(rows)
    assert_received {:prefetch, "node-cold", _}
    refute_received {:prefetch, _, _}
  end

  test "a node that may hold no pull credential is skipped, not sent a bare ref" do
    result =
      run([row("a")], credential_fun: fn _, _, _ -> {:error, {:out_of_reach, :install}} end)

    assert [{"node-a", {:skipped, {:out_of_reach, :install}}}] = result
    refute_received {:prefetch, _, _}
  end

  test "a node the registry is blocked for is skipped" do
    assert [{"node-a", {:skipped, :registry_blocked}}] =
             run([row("a", pull_blocked: ["registry.example.com"])])

    refute_received {:prefetch, _, _}
  end

  test "after_publish/3 can be switched off or replaced" do
    assert :ok = Prefetch.after_publish(%{}, %{ref: @ref}, prefetch: false)

    test = self()
    hook = &send(test, {:hook, &1, &2})
    assert :ok = Prefetch.after_publish(%{repo: "x"}, %{ref: @ref}, prefetch: hook)
    assert_received {:hook, %{repo: "x"}, %{ref: @ref}}
  end

  describe "the local machine (SI-L)" do
    test "after a publish the local store is prefetched too, whatever the node fleet is" do
      test = self()

      assert :ok =
               Prefetch.after_publish(%{repo: "vstim"}, %{ref: @ref},
                 prefetch: true,
                 async: false,
                 nodes: [],
                 local: fn ctx, published ->
                   send(test, {:local_prefetch, ctx, published})
                   :ok
                 end
               )

      assert_received {:local_prefetch, %{repo: "vstim"}, %{ref: @ref}}
    end

    test "a local prefetch that blows up neither fails the publish nor skips the nodes" do
      assert :ok =
               Prefetch.after_publish(%{workspace: %{id: "ws-1"}, repo: "vstim"}, %{ref: @ref},
                 prefetch: true,
                 async: false,
                 nodes: [row("a")],
                 local: fn _, _ -> raise "podman exploded" end,
                 send_fun: &send(self(), {:prefetch, &1, &2}),
                 credential_fun: fn _, _, _ ->
                   {:ok, %{auth: @auth, level: :repo, insecure?: false}}
                 end
               )

      assert_received {:prefetch, "node-a", _}
    end

    test "local: false leaves the local store alone" do
      assert :ok =
               Prefetch.after_publish(%{repo: "vstim"}, %{ref: @ref},
                 prefetch: true,
                 async: false,
                 nodes: [],
                 local: false
               )

      refute_received {:local_prefetch, _, _}
    end
  end
end
