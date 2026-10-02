defmodule Arbiter.Sessions.Memory.PromotionTest do
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.Config.Paths

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

    test "rejects a candidate memory", %{sessions_root: root} do
      path = write_candidate!(root, "session-1", "cand.md", "Content")

      assert :ok == Promotion.reject(path)
      assert not File.exists?(path)
    end
  end
end
