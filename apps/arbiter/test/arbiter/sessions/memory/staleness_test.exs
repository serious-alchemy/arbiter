defmodule Arbiter.Sessions.Memory.StalenessTest do
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Config.Paths

  @moduletag :tmp_dir

  defp write_memory!(root, filename, type, body, extra \\ "") do
    File.mkdir_p!(root)

    File.write!(Path.join(root, filename), """
    ---
    name: #{Path.rootname(filename)}
    description: fixture
    metadata:
      type: #{type}
    #{extra}---

    #{body}
    """)

    Path.join(root, filename)
  end

  setup %{tmp_dir: tmp_dir} do
    memory_root = Path.join(tmp_dir, "memory_root")
    File.mkdir_p!(memory_root)
    {:ok, memory_root: memory_root}
  end

  describe "check_memory/2" do
    test "returns :ok for user/feedback memories without checking", %{memory_root: root} do
      path = write_memory!(root, "user.md", "user", "Some content about user")
      assert Staleness.check_memory(path) == :ok
    end

    test "quarantines project memory with invalid file:line", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at lib/short.ex:10",
          "  workspace_id: ws1\n"
        )

      assert {:error, :quarantined} = Staleness.check_memory(path, primary_checkout: checkout)

      assert not File.exists?(path)
      quarantine_path = Path.join([root, "quarantined", "proj.md"])
      assert File.exists?(quarantine_path)
    end

    test "returns :ok for project memory with valid file:line", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at lib/short.ex:2",
          "  workspace_id: ws1\n"
        )

      assert :ok = Staleness.check_memory(path, primary_checkout: checkout)
      assert File.exists?(path)
    end
  end
end
