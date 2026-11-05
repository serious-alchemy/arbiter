defmodule Arbiter.Worker.CiUnrunTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.CiUnrun

  defmodule Unrun do
    def unrun_pipeline("!1"), do: {:ok, %{pipeline_id: 1}}
    def unrun_pipeline("!2"), do: {:ok, nil}
    def unrun_pipeline("!3"), do: {:error, :boom}
    def unrun_pipeline("!4"), do: raise("forge down")
  end

  defmodule NoCallback do
    def get(_), do: {:ok, %{}}
  end

  test "a zero-job pipeline is reported" do
    assert %{pipeline_id: 1} = CiUnrun.read(Unrun, "!1")
  end

  test "a real failure, a forge error, a raise and a missing callback all read as nil" do
    assert CiUnrun.read(Unrun, "!2") == nil
    assert CiUnrun.read(Unrun, "!3") == nil
    assert CiUnrun.read(Unrun, "!4") == nil
    assert CiUnrun.read(NoCallback, "!1") == nil
    assert CiUnrun.read(nil, "!1") == nil
    assert CiUnrun.read(Unrun, nil) == nil
  end
end
