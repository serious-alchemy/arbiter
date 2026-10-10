defmodule Arbiter.NodeAgent.K8s.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ConfigLoader

  @moduletag :tmp_dir

  defp write!(dir, text), do: File.write!(Path.join(dir, "controller.yaml"), text)

  defp start!(dir, opts \\ []) do
    start_supervised!(
      {ConfigLoader,
       opts ++ [path: Path.join(dir, "controller.yaml"), interval_ms: nil, notify: self()]}
    )
  end

  test "loads the file at start", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir)

    assert {:ok, %{max_concurrent: 4}} = ConfigLoader.current(loader)
    assert ConfigLoader.degraded(loader) == []
  end

  test "a missing file is the defaults (an unedited install has no overrides)", %{tmp_dir: dir} do
    loader = start!(dir)
    assert {:ok, %{max_concurrent: 2}} = ConfigLoader.current(loader)
    assert ConfigLoader.degraded(loader) == []
  end

  test "a reload picks up an edit and tells the subscriber", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir)
    write!(dir, "max_concurrent: 6")

    assert :ok = ConfigLoader.reload(loader)
    assert {:ok, %{max_concurrent: 6}} = ConfigLoader.current(loader)
    assert_receive {:controller_config, ^loader, %{max_concurrent: 6}}, 5_000
  end

  test "a bad edit keeps the last good config and reports degraded: bad_config", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir)
    write!(dir, "max_concurrent: 4\nprivileged: true")

    assert {:error, {:bad_config, {:unknown_key, "privileged"}}} = ConfigLoader.reload(loader)
    assert {:ok, %{max_concurrent: 4}} = ConfigLoader.current(loader)
    assert ConfigLoader.degraded(loader) == ["bad_config"]
    assert_receive {:controller_degraded, ^loader, ["bad_config"]}, 5_000
  end

  test "fixing the file clears the degradation", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir)
    write!(dir, "max_concurrent: nope")
    {:error, _} = ConfigLoader.reload(loader)
    write!(dir, "max_concurrent: 5")

    assert :ok = ConfigLoader.reload(loader)
    assert ConfigLoader.degraded(loader) == []
    assert {:ok, %{max_concurrent: 5}} = ConfigLoader.current(loader)
    assert_receive {:controller_degraded, ^loader, []}, 5_000
  end

  test "a bad file at start: no config yet, degraded", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 0")
    loader = start!(dir)

    assert {:error, :no_config} = ConfigLoader.current(loader)
    assert ConfigLoader.degraded(loader) == ["bad_config"]
  end

  test "an unreadable path other than missing is bad config, not a crash", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "controller.yaml"))
    loader = start!(dir)
    assert ConfigLoader.degraded(loader) == ["bad_config"]
  end

  test "an unchanged file notifies nobody", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir)
    assert :ok = ConfigLoader.reload(loader)
    refute_received {:controller_config, _, _}
  end

  test "subscribe/2 adds a listener after start (the controller subscribes itself)", %{
    tmp_dir: dir
  } do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir, notify: nil)
    assert :ok = ConfigLoader.subscribe(loader, self())

    write!(dir, "max_concurrent: 8")
    assert :ok = ConfigLoader.reload(loader)
    assert_receive {:controller_config, ^loader, %{max_concurrent: 8}}, 5_000
  end

  test "polls on its own interval", %{tmp_dir: dir} do
    write!(dir, "max_concurrent: 4")
    loader = start!(dir, interval_ms: 10)
    write!(dir, "max_concurrent: 7")

    assert_receive {:controller_config, ^loader, %{max_concurrent: 7}}, 2_000
  end
end
