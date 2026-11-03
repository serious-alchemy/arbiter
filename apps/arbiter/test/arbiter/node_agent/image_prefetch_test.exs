defmodule Arbiter.NodeAgent.ImagePrefetchTest do
  @moduledoc """
  SI7: the agent pulls `image.prefetch` refs in the background, one at a time.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.{ImagePrefetch, PullAuth}

  defp ref(c), do: "registry.example.com/arbiter/vstim/worker@sha256:" <> String.duplicate(c, 64)

  defp payload(c, extra \\ %{}), do: Map.merge(%{"ref" => ref(c)}, extra)

  setup do
    test = self()
    name = :"prefetch_#{System.unique_integer([:positive])}"

    # Each pull announces itself, then waits for the test to release it.
    pull_fun = fn ref, _image, auth, run, _opts ->
      send(test, {:pulling, ref, auth, run, self()})

      receive do
        :release -> :ok
        :fail -> {:error, {:image_unavailable, {:pull_failed, 1, "boom"}}}
      end
    end

    start_supervised!({ImagePrefetch, name: name, pull_fun: pull_fun})
    {:ok, opts: [name: name]}
  end

  test "pulls queued refs one at a time, in order", %{opts: opts} do
    assert :ok = ImagePrefetch.enqueue(payload("a"), opts)
    assert :ok = ImagePrefetch.enqueue(payload("b"), opts)

    ref_a = ref("a")
    ref_b = ref("b")
    assert_receive {:pulling, ^ref_a, nil, "prefetch-1", pid_a}
    # The second is held back until the first ends.
    refute_receive {:pulling, _, _, _, _}, 50
    assert %{pulling: ^ref_a, queued: [^ref_b]} = ImagePrefetch.status(opts)

    send(pid_a, :release)
    assert_receive {:pulling, ^ref_b, nil, "prefetch-2", pid_b}
    send(pid_b, :release)
  end

  test "a failed pull does not stop the queue; a repeated ref is not queued twice", %{opts: opts} do
    :ok = ImagePrefetch.enqueue(payload("a"), opts)
    :ok = ImagePrefetch.enqueue(payload("a"), opts)
    :ok = ImagePrefetch.enqueue(payload("b"), opts)

    ref_b = ref("b")
    assert_receive {:pulling, _, _, _, pid_a}
    assert %{queued: [^ref_b]} = ImagePrefetch.status(opts)

    send(pid_a, :fail)
    assert_receive {:pulling, ^ref_b, _, _, pid_b}
    send(pid_b, :release)
  end

  test "carries the pull credential for the ref's own host", %{opts: opts} do
    auth = %{"registry" => "registry.example.com", "username" => "pull", "password" => "pw"}
    :ok = ImagePrefetch.enqueue(payload("a", %{"pull_auth" => auth}), opts)

    assert_receive {:pulling, _, %PullAuth{username: "pull", password: "pw"}, _, pid}
    send(pid, :release)
  end

  test "ignores a payload it will not act on", %{opts: opts} do
    assert {:error, :bad_payload} = ImagePrefetch.enqueue(%{"ref" => "latest"}, opts)
    assert {:error, :bad_payload} = ImagePrefetch.enqueue(%{"nope" => 1}, opts)

    other = %{"registry" => "evil.example.com", "username" => "u", "password" => "p"}
    bad = payload("a", %{"pull_auth" => other})
    assert {:error, :bad_payload} = ImagePrefetch.enqueue(bad, opts)
    refute_receive {:pulling, _, _, _, _}, 50
  end
end
