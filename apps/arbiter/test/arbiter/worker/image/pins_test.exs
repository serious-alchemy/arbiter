defmodule Arbiter.Worker.Image.PinsTest do
  @moduledoc """
  bd-9r5jdt (P4): base images are pinned by digest, and the weekly refresh
  moves the pins (and so the content-hash tags built on them).
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.Pins

  @a "sha256:" <> String.duplicate("a", 64)
  @b "sha256:" <> String.duplicate("b", 64)
  @ref "docker.io/library/debian:trixie-slim"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pins-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # skopeo answers from an Agent holding ref => digest, counting calls.
  defp skopeo(registry) do
    {:ok, agent} = Agent.start_link(fn -> {registry, 0} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    runner = fn "skopeo",
                ["inspect", "--no-tags", "--format", "{{.Digest}}", "docker://" <> ref],
                _ ->
      Agent.get_and_update(agent, fn {reg, n} ->
        reply =
          case reg do
            %{^ref => digest} -> {digest <> "\n", 0}
            _ -> {"manifest unknown", 1}
          end

        {reply, {reg, n + 1}}
      end)
    end

    {agent, runner}
  end

  defp set_registry(agent, registry), do: Agent.update(agent, fn {_, n} -> {registry, n} end)
  defp calls(agent), do: Agent.get(agent, &elem(&1, 1))

  test "the first request resolves and stores the pin; later requests reuse it", %{root: root} do
    {agent, runner} = skopeo(%{@ref => @a})
    resolver = Pins.resolver(root: root, runner: runner)

    assert resolver.(@ref) == {:ok, @a}
    assert resolver.(@ref) == {:ok, @a}
    assert calls(agent) == 1
    assert Pins.load(root: root).pins[@ref]["digest"] == @a

    # The registry tag moving does not change a stored pin until a refresh.
    set_registry(agent, %{@ref => @b})
    assert resolver.(@ref) == {:ok, @a}
  end

  test "a ref the registry does not know is an error and stores nothing", %{root: root} do
    {_agent, runner} = skopeo(%{})
    assert {:error, msg} = Pins.resolver(root: root, runner: runner).(@ref)
    assert msg =~ "skopeo inspect failed"
    assert Pins.load(root: root).pins == %{}
  end

  test "a non-digest answer is rejected", %{root: root} do
    runner = fn "skopeo", _, _ -> {"not a digest\n", 0} end
    assert {:error, msg} = Pins.resolve_remote(@ref, root: root, runner: runner)
    assert msg =~ "not a sha256 digest"
  end

  test "without skopeo it falls back to podman pull + inspect" do
    runner = fn
      "skopeo", _, _ -> {"skopeo: not found", 127}
      "podman", ["pull", "--quiet", @ref], _ -> {"", 0}
      "podman", ["image", "inspect", "--format", "{{.Digest}}", @ref], _ -> {@b <> "\n", 0}
    end

    assert Pins.resolve_remote(@ref, runner: runner) == {:ok, @b}
  end

  describe "refresh/1" do
    test "re-resolves every pin, reports moved digests and records the refresh", %{root: root} do
      {agent, runner} = skopeo(%{@ref => @a, "docker.io/library/node:20" => @a})
      opts = [root: root, runner: runner]
      resolver = Pins.resolver(opts)
      {:ok, @a} = resolver.(@ref)
      {:ok, @a} = resolver.("docker.io/library/node:20")
      assert Pins.load(opts).refreshed_at == nil

      set_registry(agent, %{@ref => @b, "docker.io/library/node:20" => @a})

      assert %{changed: [{@ref, @a, @b}], failed: []} = Pins.refresh(opts)

      state = Pins.load(opts)
      assert state.pins[@ref]["digest"] == @b
      assert state.pins["docker.io/library/node:20"]["digest"] == @a
      assert is_binary(state.refreshed_at)
    end

    test "a registry failure keeps the old pin and is reported", %{root: root} do
      {agent, runner} = skopeo(%{@ref => @a})
      opts = [root: root, runner: runner]
      {:ok, @a} = Pins.resolver(opts).(@ref)
      set_registry(agent, %{})

      assert %{changed: [], failed: [{@ref, _}]} = Pins.refresh(opts)
      assert Pins.load(opts).pins[@ref]["digest"] == @a
    end
  end

  describe "due?/1" do
    defp write_state(root, pins, refreshed_at) do
      File.write!(
        Path.join(root, "pins.json"),
        Jason.encode!(%{pins: pins, refreshed_at: refreshed_at})
      )
    end

    @now ~U[2026-10-10 12:00:00Z]

    test "an install with no pins has nothing to refresh", %{root: root} do
      refute Pins.due?(root: root, now: @now)
    end

    test "due a week after the last refresh, not before", %{root: root} do
      pins = %{@ref => %{"digest" => @a, "resolved_at" => "2026-01-01T00:00:00Z"}}

      write_state(root, pins, "2026-10-03T12:00:00Z")
      assert Pins.due?(root: root, now: @now)

      write_state(root, pins, "2026-10-04T12:00:00Z")
      refute Pins.due?(root: root, now: @now)
    end

    test "before any refresh, the oldest resolution is the clock", %{root: root} do
      write_state(
        root,
        %{@ref => %{"digest" => @a, "resolved_at" => "2026-10-09T00:00:00Z"}},
        nil
      )

      refute Pins.due?(root: root, now: @now)

      write_state(
        root,
        %{@ref => %{"digest" => @a, "resolved_at" => "2026-09-01T00:00:00Z"}},
        nil
      )

      assert Pins.due?(root: root, now: @now)
    end
  end
end
