defmodule Arbiter.NodeAgent.K8s.InformerTest do
  # The informer against a fake API server: watch drops, expired resourceVersions
  # and server errors must neither lose nor duplicate a transition. Every wait is
  # a message or a server-side rendezvous (`await_watchers`), never a sleep.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.Test.FakeK8sApi

  @labels %{"arbiter.dev/install" => "inst-1", "arbiter.dev/node" => "node-1"}

  defp pod(name, phase \\ "Pending", labels \\ @labels) do
    %{"metadata" => %{"name" => name, "labels" => labels}, "status" => %{"phase" => phase}}
  end

  defp start_informer(%{client: client}, opts \\ []) do
    opts =
      Keyword.merge(
        [
          client: client,
          label_selector: Client.label_selector(@labels),
          subscriber: self(),
          backoff_ms: {5, 20}
        ],
        opts
      )

    start_supervised!({Informer, opts})
  end

  # Collects `n` transitions as {type, name, phase}.
  defp collect(informer, n, acc \\ []) do
    if length(acc) == n do
      Enum.reverse(acc)
    else
      assert_receive {:pod_event, ^informer, type, pod}, 5_000
      collect(informer, n, [{type, pod["metadata"]["name"], pod["status"]["phase"]} | acc])
    end
  end

  defp lists(api),
    do:
      Enum.count(FakeK8sApi.requests(api), &(&1.method == "GET" and &1.params["watch"] != "true"))

  defp watches(api), do: Enum.count(FakeK8sApi.requests(api), &(&1.params["watch"] == "true"))

  setup do
    {:ok, FakeK8sApi.start!()}
  end

  test "lists, announces what exists, then reports synced", ctx do
    FakeK8sApi.put_pod(ctx.api, pod("a"))
    FakeK8sApi.put_pod(ctx.api, pod("b"))
    informer = start_informer(ctx)

    assert collect(informer, 2) == [{:added, "a", "Pending"}, {:added, "b", "Pending"}]
    assert_receive {:pod_synced, ^informer}, 5_000
    assert :ok = Informer.await_sync(informer, 2_000)
    assert Informer.synced?(informer)

    assert informer |> Informer.pods() |> Enum.map(& &1["metadata"]["name"]) |> Enum.sort() == [
             "a",
             "b"
           ]
  end

  test "only pods matching the selector are seen", ctx do
    FakeK8sApi.put_pod(ctx.api, pod("mine"))
    FakeK8sApi.put_pod(ctx.api, pod("theirs", "Pending", %{"arbiter.dev/install" => "other"}))
    informer = start_informer(ctx)

    assert collect(informer, 1) == [{:added, "mine", "Pending"}]
    FakeK8sApi.await_watchers(ctx.api, 1)
    FakeK8sApi.put_pod(ctx.api, pod("theirs", "Running", %{"arbiter.dev/install" => "other"}))
    FakeK8sApi.put_pod(ctx.api, pod("mine", "Running"))
    assert collect(informer, 1) == [{:modified, "mine", "Running"}]
  end

  test "watch events arrive in order: add, modify, delete", ctx do
    informer = start_informer(ctx)
    assert_receive {:pod_synced, ^informer}, 5_000
    FakeK8sApi.await_watchers(ctx.api, 1)

    FakeK8sApi.put_pod(ctx.api, pod("p"))
    FakeK8sApi.put_pod(ctx.api, pod("p", "Running"))
    FakeK8sApi.delete_pod(ctx.api, "p")

    assert collect(informer, 3) == [
             {:added, "p", "Pending"},
             {:modified, "p", "Running"},
             {:deleted, "p", "Running"}
           ]

    assert Informer.pods(informer) == []
  end

  test "a dropped watch resumes from the last version: nothing lost, nothing duplicated, no relist",
       ctx do
    FakeK8sApi.put_pod(ctx.api, pod("a"))
    informer = start_informer(ctx)
    assert collect(informer, 1) == [{:added, "a", "Pending"}]
    FakeK8sApi.await_watchers(ctx.api, 1)

    FakeK8sApi.put_pod(ctx.api, pod("a", "Running"))
    assert collect(informer, 1) == [{:modified, "a", "Running"}]

    # The watch drops; the world moves while nobody is watching.
    FakeK8sApi.drop_watches(ctx.api)
    FakeK8sApi.put_pod(ctx.api, pod("b"))
    FakeK8sApi.put_pod(ctx.api, pod("a", "Succeeded"))
    FakeK8sApi.delete_pod(ctx.api, "b")

    assert collect(informer, 3) == [
             {:added, "b", "Pending"},
             {:modified, "a", "Succeeded"},
             {:deleted, "b", "Pending"}
           ]

    FakeK8sApi.await_watchers(ctx.api, 1)

    # ...and the live stream carries on from there.
    FakeK8sApi.put_pod(ctx.api, pod("c"))
    assert collect(informer, 1) == [{:added, "c", "Pending"}]
    refute_receive {:pod_event, ^informer, _, _}, 50

    assert lists(ctx.api) == 1
    assert watches(ctx.api) == 2
  end

  test "the resumed watch asks for the version after the last event it handled", ctx do
    informer = start_informer(ctx)
    assert_receive {:pod_synced, ^informer}, 5_000
    FakeK8sApi.await_watchers(ctx.api, 1)

    FakeK8sApi.put_pod(ctx.api, pod("a"))
    collect(informer, 1)
    seen = FakeK8sApi.current_rv(ctx.api)
    FakeK8sApi.drop_watches(ctx.api)
    FakeK8sApi.await_watchers(ctx.api, 1)

    resumed =
      ctx.api
      |> FakeK8sApi.requests()
      |> Enum.filter(&(&1.params["watch"] == "true"))
      |> List.last()

    assert resumed.params["resourceVersion"] == Integer.to_string(seen)
  end

  test "a watch cut off mid-event loses nothing: the half event is replayed whole", ctx do
    informer = start_informer(ctx)
    assert_receive {:pod_synced, ^informer}, 5_000
    FakeK8sApi.await_watchers(ctx.api, 1)

    FakeK8sApi.put_pod(ctx.api, pod("a"))
    collect(informer, 1)
    FakeK8sApi.drop_watches(ctx.api, :truncate)
    FakeK8sApi.put_pod(ctx.api, pod("a", "Running"))

    assert collect(informer, 1) == [{:modified, "a", "Running"}]
    refute_receive {:pod_event, ^informer, _, _}, 50
  end

  describe "410 Gone" do
    for mode <- [:event, :http] do
      test "an expired version (#{mode}) relists, and the diff is the missed transitions", ctx do
        FakeK8sApi.expire_with(ctx.api, unquote(mode))
        FakeK8sApi.put_pod(ctx.api, pod("keep"))
        FakeK8sApi.put_pod(ctx.api, pod("change"))
        FakeK8sApi.put_pod(ctx.api, pod("vanish"))
        informer = start_informer(ctx)
        assert length(collect(informer, 3)) == 3
        FakeK8sApi.await_watchers(ctx.api, 1)

        FakeK8sApi.drop_watches(ctx.api)
        FakeK8sApi.put_pod(ctx.api, pod("change", "Running"))
        FakeK8sApi.delete_pod(ctx.api, "vanish")
        FakeK8sApi.put_pod(ctx.api, pod("fresh"))
        FakeK8sApi.compact(ctx.api)

        events = collect(informer, 3)

        assert Enum.sort(events) ==
                 Enum.sort([
                   {:deleted, "vanish", "Pending"},
                   {:modified, "change", "Running"},
                   {:added, "fresh", "Pending"}
                 ])

        assert_receive {:pod_synced, ^informer}, 5_000
        FakeK8sApi.await_watchers(ctx.api, 1)
        refute_receive {:pod_event, ^informer, _, _}, 50
        assert lists(ctx.api) == 2
      end
    end

    test "a pod recreated during the gap (same name, new uid) is a delete then an add", ctx do
      FakeK8sApi.put_pod(ctx.api, put_in(pod("p"), ["metadata", "uid"], "first"))
      informer = start_informer(ctx)
      collect(informer, 1)
      FakeK8sApi.await_watchers(ctx.api, 1)

      FakeK8sApi.drop_watches(ctx.api)
      FakeK8sApi.delete_pod(ctx.api, "p")
      FakeK8sApi.put_pod(ctx.api, pod("p", "Running") |> put_in(["metadata", "uid"], "second"))
      FakeK8sApi.compact(ctx.api)

      assert collect(informer, 2) == [{:deleted, "p", "Pending"}, {:added, "p", "Running"}]
    end
  end

  test "a bookmark moves the resume point, so a compaction behind it is not a 410", ctx do
    informer = start_informer(ctx)
    assert_receive {:pod_synced, ^informer}, 5_000
    FakeK8sApi.await_watchers(ctx.api, 1)

    FakeK8sApi.put_pod(ctx.api, pod("a"))
    collect(informer, 1)
    # Other (non-matching) traffic advances the cluster version; history is then compacted.
    FakeK8sApi.put_pod(ctx.api, pod("noise", "Pending", %{"x" => "y"}))
    FakeK8sApi.compact(ctx.api)
    FakeK8sApi.bookmark(ctx.api)
    bookmark_rv = Integer.to_string(FakeK8sApi.current_rv(ctx.api))
    assert_receive {:pod_bookmark, ^informer, ^bookmark_rv}, 5_000
    FakeK8sApi.drop_watches(ctx.api)
    FakeK8sApi.await_watchers(ctx.api, 1)

    assert lists(ctx.api) == 1
    assert watches(ctx.api) == 2
  end

  describe "failures" do
    test "a failing list is retried with backoff until it works", ctx do
      FakeK8sApi.put_pod(ctx.api, pod("a"))
      FakeK8sApi.fail_next(ctx.api, :list, 500, 2)
      informer = start_informer(ctx)

      assert collect(informer, 1) == [{:added, "a", "Pending"}]
      assert lists(ctx.api) == 3
    end

    test "a failing watch is retried from the same version, without a relist", ctx do
      informer = start_informer(ctx, [])
      assert_receive {:pod_synced, ^informer}, 5_000
      FakeK8sApi.await_watchers(ctx.api, 1)
      FakeK8sApi.fail_next(ctx.api, :watch, 503, 2)
      FakeK8sApi.drop_watches(ctx.api)
      FakeK8sApi.await_watchers(ctx.api, 1)

      FakeK8sApi.put_pod(ctx.api, pod("late"))
      assert collect(informer, 1) == [{:added, "late", "Pending"}]
      assert lists(ctx.api) == 1
    end

    test "an unreachable API server does not crash the informer; it recovers when the server is back",
         ctx do
      FakeK8sApi.put_pod(ctx.api, pod("a"))
      FakeK8sApi.fail_next(ctx.api, :list, 401, 3)
      informer = start_informer(ctx)
      assert collect(informer, 1) == [{:added, "a", "Pending"}]
      assert Process.alive?(informer)
    end
  end

  describe "subscribers" do
    test "subscribe/2 returns a snapshot and then only later transitions", ctx do
      FakeK8sApi.put_pod(ctx.api, pod("a"))
      informer = start_informer(ctx, subscriber: nil)
      :ok = Informer.await_sync(informer, 2_000)
      FakeK8sApi.await_watchers(ctx.api, 1)

      assert {:ok, [snapshot]} = Informer.subscribe(informer)
      assert snapshot["metadata"]["name"] == "a"
      refute_receive {:pod_event, ^informer, _, _}, 20

      FakeK8sApi.put_pod(ctx.api, pod("b"))
      assert collect(informer, 1) == [{:added, "b", "Pending"}]
    end

    test "a subscriber that dies is dropped; the informer carries on", ctx do
      informer = start_informer(ctx, subscriber: nil)
      :ok = Informer.await_sync(informer, 2_000)

      parent = self()

      sub =
        spawn(fn ->
          Informer.subscribe(informer)
          send(parent, :subscribed)
          Process.sleep(:infinity)
        end)

      assert_receive :subscribed, 5_000
      assert Informer.subscribers(informer) == [sub]
      ref = Process.monitor(sub)
      Process.exit(sub, :kill)
      assert_receive {:DOWN, ^ref, :process, ^sub, :killed}, 5_000

      # A call after the DOWN was sent is handled after the informer saw it.
      assert {:ok, _} = Informer.subscribe(informer)
      assert Informer.subscribers(informer) == [self()]
    end

    test "await_sync times out when there is no server", ctx do
      informer = start_informer(ctx, client: %{ctx.client | base_url: "http://127.0.0.1:1"})
      assert {:error, :timeout} = Informer.await_sync(informer, 50)
    end
  end
end
