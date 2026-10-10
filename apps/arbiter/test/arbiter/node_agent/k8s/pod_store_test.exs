defmodule Arbiter.NodeAgent.K8s.PodStoreTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.PodStore

  defp pod(name, rv, uid \\ nil),
    do: %{
      "metadata" => %{"name" => name, "resourceVersion" => rv, "uid" => uid || "uid-" <> name}
    }

  defp names(events), do: Enum.map(events, fn {type, p} -> {type, p["metadata"]["name"]} end)

  describe "replace/3 (a list): the diff against what we held is the same transitions a watch would give" do
    test "first list: everything is added, in name order" do
      {events, store} = PodStore.replace(PodStore.new(), [pod("b", "2"), pod("a", "1")], "5")
      assert names(events) == [added: "a", added: "b"]
      assert PodStore.resource_version(store) == "5"
      assert Map.keys(PodStore.pods(store)) == ["a", "b"]
    end

    test "relist: unchanged pods emit nothing, changed ones modified, new ones added, missing ones deleted" do
      {_, store} =
        PodStore.replace(
          PodStore.new(),
          [pod("keep", "1"), pod("chg", "2"), pod("gone", "3")],
          "5"
        )

      {events, store} =
        PodStore.replace(store, [pod("keep", "1"), pod("chg", "9"), pod("new", "8")], "10")

      assert names(events) == [deleted: "gone", modified: "chg", added: "new"]
      assert PodStore.resource_version(store) == "10"
      refute Map.has_key?(PodStore.pods(store), "gone")
    end

    test "a pod recreated under the same name (new uid) is deleted then added, not modified" do
      {_, store} = PodStore.replace(PodStore.new(), [pod("p", "1", "old")], "5")
      {events, _} = PodStore.replace(store, [pod("p", "7", "new")], "10")
      assert names(events) == [deleted: "p", added: "p"]

      assert [
               {:deleted, %{"metadata" => %{"uid" => "old"}}},
               {:added, %{"metadata" => %{"uid" => "new"}}}
             ] = events
    end
  end

  describe "apply_event/3" do
    setup do
      {_, store} = PodStore.replace(PodStore.new(), [pod("p", "1")], "5")
      %{store: store}
    end

    test "added / modified / deleted advance the version and emit once", %{store: store} do
      {ev, store} = PodStore.apply_event(store, :added, pod("q", "6"))
      assert names(ev) == [added: "q"]
      assert PodStore.resource_version(store) == "6"

      {ev, store} = PodStore.apply_event(store, :modified, pod("q", "7"))
      assert names(ev) == [modified: "q"]

      {ev, store} = PodStore.apply_event(store, :deleted, pod("q", "8"))
      assert names(ev) == [deleted: "q"]
      assert PodStore.resource_version(store) == "8"
      refute Map.has_key?(PodStore.pods(store), "q")
    end

    test "the same event twice is delivered once", %{store: store} do
      {[_], store} = PodStore.apply_event(store, :modified, pod("p", "2"))
      assert {[], ^store} = PodStore.apply_event(store, :modified, pod("p", "2"))
    end

    test "ADDED for a pod we already hold is a modification, or nothing when identical", %{
      store: store
    } do
      assert {[], _} = PodStore.apply_event(store, :added, pod("p", "1"))
      assert {[{:modified, _}], _} = PodStore.apply_event(store, :added, pod("p", "4"))
    end

    test "DELETED for a pod we never held emits nothing but still moves the version", %{
      store: store
    } do
      {events, store} = PodStore.apply_event(store, :deleted, pod("ghost", "9"))
      assert events == []
      assert PodStore.resource_version(store) == "9"
    end

    test "a DELETED for an older incarnation does not remove the new one", %{store: store} do
      {_, store} = PodStore.replace(store, [pod("p", "6", "second")], "6")
      assert {[], store} = PodStore.apply_event(store, :deleted, pod("p", "7", "uid-p"))
      assert Map.has_key?(PodStore.pods(store), "p")
    end

    test "MODIFIED with a new uid replaces the pod (delete + add)", %{store: store} do
      {events, _} = PodStore.apply_event(store, :modified, pod("p", "9", "other"))
      assert names(events) == [deleted: "p", added: "p"]
    end

    test "the deleted event carries the final object from the event, not the stale one", %{
      store: store
    } do
      final = put_in(pod("p", "9"), ["status"], %{"phase" => "Failed"})
      {[{:deleted, got}], _} = PodStore.apply_event(store, :deleted, final)
      assert got["status"]["phase"] == "Failed"
    end
  end

  describe "bookmark/2 and expire/1" do
    test "a bookmark advances the version without touching pods" do
      {_, store} = PodStore.replace(PodStore.new(), [pod("p", "1")], "5")
      store = PodStore.bookmark(store, "42")
      assert PodStore.resource_version(store) == "42"
      assert Map.keys(PodStore.pods(store)) == ["p"]
    end

    test "expire clears the version (forcing a relist) but keeps the pods for the diff" do
      {_, store} = PodStore.replace(PodStore.new(), [pod("p", "1")], "5")
      store = PodStore.expire(store)
      assert PodStore.resource_version(store) == nil
      assert Map.keys(PodStore.pods(store)) == ["p"]
    end
  end
end
