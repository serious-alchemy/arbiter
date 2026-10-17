defmodule Arbiter.RuntimeJailUnmaskTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)

  defp unmask(value, home \\ "/home/t") do
    old = for k <- ["ARB_WORKER_JAIL_UNMASK", "HOME"], do: {k, System.get_env(k)}

    on_exit(fn -> Enum.each(old, fn {k, v} -> restore(k, v) end) end)
    restore("HOME", home)
    restore("ARB_WORKER_JAIL_UNMASK", value)

    @runtime
    |> Config.Reader.read!(env: :test)
    |> Keyword.fetch!(:arbiter)
    |> Keyword.fetch!(:worker_jail_unmask)
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  test "colon-separated paths, ~ expanded against HOME" do
    assert unmask("/home/x/.config/glab-cli:~/.config/foo") ==
             ["/home/x/.config/glab-cli", "/home/t/.config/foo"]
  end

  test "comma-separated" do
    assert unmask("/a,/b") == ["/a", "/b"]
  end

  test "unset or empty is []" do
    assert unmask(nil) == []
    assert unmask("") == []
  end

  test "malformed entries are skipped, not fatal" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(self(), {:r, unmask("relative/path:/ok")})
    end)

    assert_received {:r, ["/ok"]}
  end
end
