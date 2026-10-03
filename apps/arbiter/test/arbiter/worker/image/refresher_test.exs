defmodule Arbiter.Worker.Image.RefresherTest do
  @moduledoc """
  bd-9r5jdt (P4): the weekly base refresh + prune, driven synchronously
  through `run_now/2` (the timer is disabled in test).
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.Pins
  alias Arbiter.Worker.Image.Refresher

  @a "sha256:" <> String.duplicate("a", 64)
  @b "sha256:" <> String.duplicate("b", 64)
  @ref "docker.io/library/debian:bookworm-slim"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "refresher-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp images_json do
    for {h, t} <- [{"a", 1}, {"b", 2}, {"c", 3}] do
      %{
        "Id" => "id#{h}",
        "Names" => ["localhost/arbiter-dev/x:#{String.duplicate(h, 12)}"],
        "Created" => t,
        "Size" => 1,
        "Labels" => %{"arbiter.dev-image" => "1"}
      }
    end
    |> Jason.encode!()
  end

  defp runner(test_pid, digest) do
    fn cmd, args, _ ->
      send(test_pid, {:ran, cmd, args})

      case {cmd, args} do
        {"skopeo", ["inspect" | _]} -> {digest <> "\n", 0}
        {"podman", ["images" | _]} -> {images_json(), 0}
        {"podman", ["rmi", _]} -> {"", 0}
      end
    end
  end

  defp seed(root, resolved_at, refreshed_at) do
    File.write!(
      Path.join(root, "pins.json"),
      Jason.encode!(%{
        pins: %{@ref => %{"digest" => @a, "resolved_at" => resolved_at}},
        refreshed_at: refreshed_at
      })
    )
  end

  test "when due, re-resolves the pins and prunes stale images", %{root: root} do
    seed(root, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z")
    pid = start_supervised!({Refresher, name: nil, enabled: false})

    assert {:ran, %{changed: [{@ref, @a, @b}], pruned: pruned}} =
             Refresher.run_now(pid, root: root, runner: runner(self(), @b))

    assert pruned.removed == ["localhost/arbiter-dev/x:" <> String.duplicate("a", 12)]
    assert Pins.load(root: root).pins[@ref]["digest"] == @b
    assert_received {:ran, "skopeo", _}
    assert_received {:ran, "podman", ["rmi", _]}
  end

  test "when not due, touches nothing", %{root: root} do
    seed(root, "2026-01-01T00:00:00Z", DateTime.to_iso8601(DateTime.utc_now()))
    pid = start_supervised!({Refresher, name: nil, enabled: false})

    assert :not_due = Refresher.run_now(pid, root: root, runner: runner(self(), @b))
    refute_received {:ran, _, _}
    assert Pins.load(root: root).pins[@ref]["digest"] == @a
  end

  test "force: true refreshes even when not due", %{root: root} do
    seed(root, "2026-01-01T00:00:00Z", DateTime.to_iso8601(DateTime.utc_now()))
    pid = start_supervised!({Refresher, name: nil, enabled: false})

    assert {:ran, %{changed: [_]}} =
             Refresher.run_now(pid, root: root, runner: runner(self(), @b), force: true)
  end

  test "an install that never built an image is never refreshed", %{root: root} do
    pid = start_supervised!({Refresher, name: nil, enabled: false})
    assert :not_due = Refresher.run_now(pid, root: root, runner: runner(self(), @b))
    refute_received {:ran, _, _}
  end
end
