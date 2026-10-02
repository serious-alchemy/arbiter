defmodule Arbiter.Sessions.MemoryTest do
  @moduledoc """
  Phase 12 (bd-6dkpf1, RFC §9.4): type-scoped read-only shared memory mounts.

  Acceptance criteria 1 and 3 — provisioning mounts memory by
  `metadata.type`, `project` memories are filtered to the session's bound
  workspace, and a cross-workspace session receives none of them.

  Phase 13 (bd-19qve3, amendment 3): a mount serves only memories whose
  stored verdict is current and not stale, and never verifies anything itself.
  The phase-12 cases therefore run the checker before mounting.
  """
  use ExUnit.Case, async: false

  import Arbiter.Test.MemoryFixture, only: [checkout!: 1, commit!: 2]

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts
  alias Arbiter.Sessions.Session

  @moduletag :tmp_dir

  @short "defmodule Short do\n  def hello, do: :world\nend\n"

  defp write_memory!(root, filename, type, extra \\ "", body \\ nil) do
    File.mkdir_p!(root)
    path = Path.join(root, filename)

    File.write!(path, """
    ---
    name: #{Path.rootname(filename)}
    description: fixture
    metadata:
      type: #{type}
    #{extra}---

    #{body || "Fixture body for #{filename}."}
    """)

    path
  end

  defp check!(root, checkouts \\ []) do
    Checker.run(memory_root: root, checkouts: checkouts, ticket_prefixes: [])
  end

  defp session(id, workspace_id \\ nil) do
    %Session{id: id, workspace_id: workspace_id}
  end

  defp mounted(s, type), do: s.id |> Layout.memory_shared_dir() |> Path.join(type) |> File.ls!()

  setup %{tmp_dir: tmp_dir} do
    memory_root = Path.join(tmp_dir, "memory_root")
    sessions_root = Path.join(tmp_dir, "sessions")
    File.mkdir_p!(memory_root)

    prior = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, sessions_root)
    on_exit(fn -> restore(:sessions_root, prior) end)

    {:ok, memory_root: memory_root}
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, val), do: Application.put_env(:arbiter, key, val)

  describe "mount/2" do
    test "mounts user, feedback and reference read-only for every session", %{
      memory_root: root
    } do
      write_memory!(root, "user-fact.md", "user")
      write_memory!(root, "feedback-fact.md", "feedback")
      write_memory!(root, "reference-fact.md", "reference")
      check!(root)

      s = session("sess-shared")
      :ok = Memory.mount(s, memory_root: root)

      shared = Layout.memory_shared_dir(s.id)
      assert File.read_link(Path.join([shared, "user", "user-fact.md"])) |> elem(0) == :ok
      assert File.read_link(Path.join([shared, "feedback", "feedback-fact.md"])) |> elem(0) == :ok

      assert File.read_link(Path.join([shared, "reference", "reference-fact.md"])) |> elem(0) ==
               :ok
    end

    test "cross-workspace session receives no project memories", %{memory_root: root} do
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")
      check!(root)

      s = session("sess-cross", nil)
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "project") == []
    end

    test "a bound session receives only its own workspace's project memories", %{
      memory_root: root
    } do
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")
      write_memory!(root, "vstim-fact.md", "project", "  workspace_id: ws-vstim\n")
      check!(root)

      s = session("sess-vstim", "ws-vstim")
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "project") == ["vstim-fact.md"]
    end

    test "shared types are still mounted for a workspace-bound session", %{memory_root: root} do
      write_memory!(root, "user-fact.md", "user")
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")
      check!(root)

      s = session("sess-bound-shared", "ws-vstim")
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "user") == ["user-fact.md"]
      assert mounted(s, "project") == []
    end

    test "re-mounting clears a stale symlink (idempotent re-provision)", %{memory_root: root} do
      write_memory!(root, "user-fact.md", "user")
      check!(root)
      s = session("sess-idempotent")

      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "user") == ["user-fact.md"]

      File.rm!(Path.join(root, "user-fact.md"))
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "user") == []
    end

    test "a missing memory root is a no-op, not an error", %{memory_root: root} do
      missing = Path.join(root, "does-not-exist")
      s = session("sess-missing-root")

      assert :ok = Memory.mount(s, memory_root: missing)
      assert File.dir?(Layout.memory_shared_dir(s.id))
    end
  end

  describe "mount/2 serves only verified memory (bd-19qve3)" do
    test "a valid project memory is mounted and a stale one is not", %{memory_root: root} do
      checkout = checkout!(%{"lib/short.ex" => @short})
      ws = "  workspace_id: ws-arbiter\n"
      write_memory!(root, "good.md", "project", ws, "This is a good citation: lib/short.ex:2")
      write_memory!(root, "bad.md", "project", ws, "This is a bad citation: lib/short.ex:100")
      check!(root, [checkout])

      s = session("sess-valid-stale", "ws-arbiter")
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "project") == ["good.md"]
    end

    test "a memory nobody has checked yet waits for the checker", %{memory_root: root} do
      write_memory!(root, "user-fact.md", "user")
      s = session("sess-unchecked")

      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "user") == []

      check!(root)
      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "user") == ["user-fact.md"]
    end

    test "a stale verdict hides a memory even before the checker moves it", %{memory_root: root} do
      path = write_memory!(root, "user-fact.md", "user")
      {:ok, verdict} = Staleness.verify(path, checkouts: [])
      :ok = Verdicts.write(root, "user-fact.md", %{verdict | status: :stale})

      s = session("sess-stale-verdict")
      :ok = Memory.mount(s, memory_root: root)

      assert mounted(s, "user") == []
    end

    test "an edit after the check hides the memory until it is re-checked", %{memory_root: root} do
      path = write_memory!(root, "user-fact.md", "user")
      check!(root)
      File.write!(path, File.read!(path) <> "An unverified edit.\n")

      s = session("sess-edited")
      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "user") == []

      check!(root)
      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "user") == ["user-fact.md"]
    end

    # Amendment 3: a launch reads the stored verdict and does no git work, so
    # code that moved since the last checker pass is caught by the next pass,
    # not by the launch.
    test "mount reads the stored verdict and never re-verifies", %{memory_root: root} do
      checkout = checkout!(%{"lib/short.ex" => @short, "README.md" => "r\n"})
      ws = "  workspace_id: ws-arbiter\n"
      write_memory!(root, "good.md", "project", ws, "See lib/short.ex:2")
      check!(root, [checkout])

      commit!(checkout, %{"lib/short.ex" => :delete})

      s = session("sess-no-verify", "ws-arbiter")
      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "project") == ["good.md"]

      check!(root, [checkout])
      :ok = Memory.mount(s, memory_root: root)
      assert mounted(s, "project") == []
    end

    test "a project memory whose workspace has no checkout is unverified and still mounted", %{
      memory_root: root
    } do
      write_memory!(
        root,
        "proj.md",
        "project",
        "  workspace_id: ws-unknown\n",
        "See lib/missing.ex:100"
      )

      check!(root, [])

      s = session("sess-unresolvable", "ws-unknown")
      :ok = Memory.mount(s, memory_root: root)

      assert {:ok, %{status: :unverified}} = Verdicts.read(root, "proj.md")
      assert mounted(s, "project") == ["proj.md"]
    end
  end
end
