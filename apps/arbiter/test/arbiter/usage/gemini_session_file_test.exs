defmodule Arbiter.Usage.GeminiSessionFileTest do
  use ExUnit.Case, async: true

  alias Arbiter.Usage.GeminiSessionFile

  setup do
    home = Path.join(System.tmp_dir!(), "gemini-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    %{home: home}
  end

  defp seed_db(home, session_id, bytes \\ "fake-sqlite-bytes") do
    dir = Path.join([home, ".gemini", "antigravity-cli", "conversations"])
    File.mkdir_p!(dir)
    path = Path.join(dir, session_id <> ".db")
    File.write!(path, bytes)
    path
  end

  describe "locate/2" do
    test "finds the conversation db by session id under the isolated HOME", %{home: home} do
      sid = "11111111-1111-1111-1111-111111111111"
      path = seed_db(home, sid)

      assert {:ok, ^path} = GeminiSessionFile.locate(home, sid)
    end

    test "returns :not_found when the db does not exist", %{home: home} do
      assert :not_found = GeminiSessionFile.locate(home, "no-such-session")
    end

    test "returns :not_found for blank home or session id" do
      assert :not_found = GeminiSessionFile.locate(nil, "sid")
      assert :not_found = GeminiSessionFile.locate("", "sid")
      assert :not_found = GeminiSessionFile.locate("/home/x", nil)
      assert :not_found = GeminiSessionFile.locate("/home/x", "")
    end
  end

  describe "path/2" do
    test "is the deterministic path locate/2 checks", %{home: home} do
      sid = "22222222-2222-2222-2222-222222222222"

      assert GeminiSessionFile.path(home, sid) ==
               Path.join([home, ".gemini", "antigravity-cli", "conversations", sid <> ".db"])
    end
  end
end
