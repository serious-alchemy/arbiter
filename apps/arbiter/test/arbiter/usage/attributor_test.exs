defmodule Arbiter.Usage.AttributorTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Usage.Attributor
  alias Arbiter.Usage.Event

  defmodule FakeAttributor do
    @behaviour Arbiter.Usage.Attributor

    @impl true
    def attribute(attrs), do: %{"team" => "platform", "cost_centre" => "cc-#{attrs.step}"}
  end

  defmodule Boom do
    def attribute(_), do: raise("boom")
  end

  defp create!(extra \\ %{}) do
    Ash.create!(
      Event,
      Map.merge(
        %{
          task_id: "bd-attr1",
          source: :task,
          step: :work,
          workspace_id: "ws-1",
          repo: "acme/widgets",
          provider: "claude",
          model: "sonnet",
          occurred_at: DateTime.utc_now()
        },
        extra
      )
    )
  end

  setup do
    previous = Application.get_env(:arbiter, :usage_attributor)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:arbiter, :usage_attributor, previous),
        else: Application.delete_env(:arbiter, :usage_attributor)
    end)

    Application.delete_env(:arbiter, :usage_attributor)
    :ok
  end

  test "default attributor fills the core-known dimensions" do
    event = create!()

    assert event.attribution == %{
             "workspace_id" => "ws-1",
             "repo" => "acme/widgets",
             "provider" => "claude",
             "model" => "sonnet",
             "step" => "work",
             "source" => "task"
           }

    assert Ash.get!(Event, event.id).attribution == event.attribution
  end

  test "a configured attributor sets custom dimensions on top of the core ones" do
    Application.put_env(:arbiter, :usage_attributor, FakeAttributor)
    event = create!()

    assert event.attribution["team"] == "platform"
    assert event.attribution["cost_centre"] == "cc-work"
    assert event.attribution["workspace_id"] == "ws-1"
  end

  test "an attributor that raises or returns junk never blocks the write" do
    Application.put_env(:arbiter, :usage_attributor, Boom)
    event = create!()
    assert event.attribution["workspace_id"] == "ws-1"
    assert Attributor.resolve(%{}) == %{}
  end
end
