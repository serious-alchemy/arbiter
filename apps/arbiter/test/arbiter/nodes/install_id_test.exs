defmodule Arbiter.Nodes.InstallIdTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.InstallId

  @moduletag :tmp_dir

  test "is minted once, persisted next to arbiter.pid, and stable", %{tmp_dir: home} do
    id = InstallId.get(home)

    assert id =~ ~r/\A[a-z0-9]{16,}\z/
    assert File.read!(Path.join(home, "install-id")) |> String.trim() == id
    assert InstallId.get(home) == id
  end

  test "two data homes are two installs", %{tmp_dir: home} do
    a = InstallId.get(Path.join(home, "a"))
    b = InstallId.get(Path.join(home, "b"))
    refute a == b
  end

  test "an unreadable or malformed file is replaced, never trusted", %{tmp_dir: home} do
    File.write!(Path.join(home, "install-id"), "not an id!\n")
    id = InstallId.get(home)
    assert id =~ ~r/\A[a-z0-9]{16,}\z/
  end
end
