defmodule Arbiter.Sessions.Memory.PromotionTest do
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.MCP.Tools.MemoryPending
  alias Arbiter.MCP.Scope

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    sessions_root = Path.join(tmp_dir, "sessions")
    memory_root = Path.join(tmp_dir, "memory")
    File.mkdir_p!(sessions_root)
    File.mkdir_p!(memory_root)

    prior_sessions = Application.get_env(:arbiter, :sessions_root)
    prior_memory = Application.get_env(:arbiter, :memory_root)
    Application.put_env(:arbiter, :sessions_root, sessions_root)
    Application.put_env(:arbiter, :memory_root, memory_root)

    on_exit(fn ->
      restore(:sessions_root, prior_sessions)
      restore(:memory_root, prior_memory)
    end)

    {:ok, sessions_root: sessions_root, memory_root: memory_root}
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, val), do: Application.put_env(:arbiter, key, val)

  defp write_candidate!(root, session_id, filename, content) do
    dir = Path.join([root, session_id, "memory", "candidates"])
    File.mkdir_p!(dir)
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  describe "promotion queue" do
    test "lists candidates across multiple sessions", %{sessions_root: root} do
      write_candidate!(root, "session-1", "cand1.md", "Content 1")
      write_candidate!(root, "session-2", "cand2.md", "Content 2")

      candidates = Promotion.list_candidates()
      assert length(candidates) == 2

      filenames = Enum.map(candidates, & &1.filename) |> Enum.sort()
      assert filenames == ["cand1.md", "cand2.md"]
    end

    test "promotes a candidate memory", %{sessions_root: sessions_root, memory_root: mem_root} do
      path = write_candidate!(sessions_root, "session-1", "cand.md", "Content")

      assert :ok == Promotion.promote(path, memory_root: mem_root)

      assert not File.exists?(path)
      assert File.exists?(Path.join(mem_root, "cand.md"))
    end
    
    test "returns :exists if trying to overwrite without overwrite option", %{sessions_root: sessions_root, memory_root: mem_root} do
      path = write_candidate!(sessions_root, "session-1", "cand.md", "Content")
      File.write!(Path.join(mem_root, "cand.md"), "Existing content")
      
      assert {:error, :exists} = Promotion.promote(path, memory_root: mem_root)
      
      assert :ok == Promotion.promote(path, memory_root: mem_root, overwrite: true)
    end

    test "rejects a candidate memory", %{sessions_root: root} do
      path = write_candidate!(root, "session-1", "cand.md", "Content")

      assert :ok == Promotion.reject(path)
      assert not File.exists?(path)
    end
    
    test "diff returns correct simulated diff", %{sessions_root: root, memory_root: mem_root} do
      path = write_candidate!(root, "session-1", "cand.md", "New Content")
      File.write!(Path.join(mem_root, "cand.md"), "Old Content")
      
      assert {:ok, diff} = Promotion.diff(path, memory_root: mem_root)
      assert diff =~ "Old Content"
      assert diff =~ "New Content"
    end
    
    test "path-escape rejection on promote/reject/diff", %{sessions_root: root} do
      path = Path.join(root, "session-1/memory/candidates/../../../../etc/passwd")
      assert {:error, :invalid_path} = Promotion.promote(path)
      assert {:error, :invalid_path} = Promotion.reject(path)
      assert {:error, :invalid_path} = Promotion.diff(path)
      
      bad_path2 = "/tmp/some_other_file.md"
      assert {:error, :invalid_path} = Promotion.promote(bad_path2)
    end
  end
  
  describe "MCP handlers" do
    test "memory_pending_list", %{sessions_root: root} do
      write_candidate!(root, "session-1", "cand1.md", "Content 1")
      assert {:ok, %{count: 1}} = MemoryPending.memory_pending_list(%Scope{tier: :worker}, %{})
    end
    
    test "memory_pending_diff", %{sessions_root: root, memory_root: mem_root} do
      path = write_candidate!(root, "session-1", "cand.md", "New Content")
      assert {:ok, %{diff: diff}} = MemoryPending.memory_pending_diff(%Scope{tier: :worker}, %{"path" => path})
      assert diff == "New Content"
    end
    
    test "memory_pending_apply", %{sessions_root: root, memory_root: mem_root} do
      path = write_candidate!(root, "session-1", "cand.md", "Content")
      assert {:ok, %{status: "promoted"}} = MemoryPending.memory_pending_apply(%Scope{tier: :worker}, %{"path" => path})
    end
    
    test "memory_pending_apply rejects path escape", %{sessions_root: root} do
      assert {:error, {:invalid_arguments, _}} = MemoryPending.memory_pending_apply(%Scope{tier: :worker}, %{"path" => "/tmp/bad.md"})
    end
    
    test "memory_pending_reject", %{sessions_root: root} do
      path = write_candidate!(root, "session-1", "cand.md", "Content")
      assert {:ok, %{status: "rejected"}} = MemoryPending.memory_pending_reject(%Scope{tier: :worker}, %{"path" => path})
    end
  end
end
