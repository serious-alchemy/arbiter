defmodule Arbiter.Sessions.Memory.StalenessTest do
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Memory.Staleness

  @moduletag :tmp_dir

  defp write_memory!(root, filename, type, body, extra \\ "") do
    File.mkdir_p!(root)

    File.write!(Path.join(root, filename), """
    ---
    name: #{Path.rootname(filename)}
    description: fixture
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
    test "returns :ok for user/feedback/reference memories without checking", %{memory_root: root} do
      path = write_memory!(root, "user.md", "user", "Some content about user")
      assert Staleness.check_memory(path) == :ok

      path2 = write_memory!(root, "ref.md", "reference", "Look at example.com:443")
      assert Staleness.check_memory(path2) == :ok
    end

    test "identifies stale project memory with invalid file:line", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      # Initialize a dummy git repo so `git grep` and `git rev-parse HEAD` don't crash
      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at lib/short.ex:10",
          "workspace_id: ws1\n"
        )

      assert {:error, :stale, _} = Staleness.check_memory(path, primary_checkout: checkout)
    end

    test "identifies stale project memory with invalid workspace-rooted module name", %{
      memory_root: root
    } do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at Short.Missing",
          "workspace_id: ws1\n"
        )

      assert {:error, :stale, _} = Staleness.check_memory(path, primary_checkout: checkout)
    end

    test "ignores dependency modules like Ecto.Changeset", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short.Module do\nend\n")

      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at Ecto.Changeset without backticks",
          "workspace_id: ws1\n"
        )

      assert {:ok, _} = Staleness.check_memory(path, primary_checkout: checkout)
    end

    test "ignores dependency modules in backticks like `Ecto.Changeset`", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at `Ecto.Changeset`",
          "workspace_id: ws1\n"
        )

      assert {:ok, _} = Staleness.check_memory(path, primary_checkout: checkout)
    end

    test "returns :ok for project memory with valid file:line and module", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short.Module do\nend\n")

      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at lib/short.ex:2 and Short.Module",
          "workspace_id: ws1\n"
        )

      assert {:ok, _} = Staleness.check_memory(path, primary_checkout: checkout)
    end
  end

  describe "sweep/2" do
    test "quarantines stale memories", %{memory_root: root} do
      checkout = Path.join(root, "checkout")
      File.mkdir_p!(Path.join(checkout, "lib"))
      File.write!(Path.join(checkout, "lib/short.ex"), "defmodule Short do\nend\n")

      System.cmd("git", ["init"], cd: checkout)
      System.cmd("git", ["add", "."], cd: checkout)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: checkout)
      System.cmd("git", ["config", "user.name", "Test"], cd: checkout)
      System.cmd("git", ["commit", "-m", "init"], cd: checkout)

      path =
        write_memory!(
          root,
          "proj.md",
          "project",
          "Look at lib/short.ex:10",
          "workspace_id: ws1\n"
        )

      Staleness.sweep(root, primary_checkout: checkout)

      assert not File.exists?(path)
      quarantine_path = Path.join([root, "quarantined", "proj.md"])
      assert File.exists?(quarantine_path)

      content = File.read!(quarantine_path)
      assert content =~ "quarantine_reason:"
      assert content =~ "quarantine_sha:"
    end
  end
end
