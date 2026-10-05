defmodule Arbiter.Agents.Codex.AuthSyncTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Codex.AuthSync

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp auth(refresh, last_refresh) do
    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" => "id",
        "access_token" => "access-" <> refresh,
        "refresh_token" => refresh,
        "account_id" => "acct"
      },
      "last_refresh" => last_refresh
    })
  end

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "operator/auth.json")
    run = Path.join(dir, "run/codex-home/auth.json")
    File.mkdir_p!(Path.dirname(source))
    File.mkdir_p!(Path.dirname(run))
    %{source: source, run: run}
  end

  describe "seed/2" do
    test "copies the source as a private regular file, never a link", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      File.chmod!(s, 0o644)

      assert :ok = AuthSync.seed(s, r)

      assert File.read!(r) == File.read!(s)
      assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(r)
      assert Bitwise.band(mode, 0o777) == 0o600
      refute match?({:ok, _}, File.read_link(r))
    end

    test "replaces a symlink planted at the destination without writing through it", %{
      source: s,
      run: r,
      tmp_dir: dir
    } do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      victim = Path.join(dir, "victim")
      File.write!(victim, "keep")
      File.ln_s!(victim, r)

      assert :ok = AuthSync.seed(s, r)

      assert File.read!(victim) == "keep"
      assert File.read!(r) == File.read!(s)
    end

    test "no source login is :no_source and leaves no file", %{source: s, run: r} do
      assert :no_source = AuthSync.seed(s, r)
      refute File.exists?(r)
    end

    test "a source that is a symlink is copied by content", %{source: s, run: r, tmp_dir: dir} do
      real = Path.join(dir, "dotfiles-auth.json")
      File.write!(real, auth("rt-0", "2026-10-01T00:00:00Z"))
      File.ln_s!(real, s)

      assert :ok = AuthSync.seed(s, r)
      assert File.read!(r) == File.read!(real)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(r)
    end
  end

  describe "sync/2" do
    test "an untouched copy changes nothing", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)

      assert :unchanged = AuthSync.sync(s, r)
      assert File.read!(s) == auth("rt-0", "2026-10-01T00:00:00Z")
    end

    test "a rotated token in the run copy is adopted into the source", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)
      File.write!(r, auth("rt-1", "2026-10-02T00:00:00Z"))

      assert :adopted = AuthSync.sync(s, r)

      assert File.read!(s) == auth("rt-1", "2026-10-02T00:00:00Z")
      assert {:ok, %File.Stat{mode: mode}} = File.stat(s)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Path.wildcard(Path.join(Path.dirname(s), "*.arb-*")) == []
    end

    test "adopting is idempotent", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)
      File.write!(r, auth("rt-1", "2026-10-02T00:00:00Z"))

      assert :adopted = AuthSync.sync(s, r)
      assert :unchanged = AuthSync.sync(s, r)
    end

    test "a rotation that is OLDER than the source never overwrites it", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)
      # A sibling run rotated and was adopted first.
      File.write!(s, auth("rt-2", "2026-10-03T00:00:00Z"))
      File.write!(r, auth("rt-1", "2026-10-02T00:00:00Z"))

      assert :superseded = AuthSync.sync(s, r)
      assert File.read!(s) == auth("rt-2", "2026-10-03T00:00:00Z")
    end

    test "a damaged run copy is ignored", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)

      for bad <- ["", "not json", ~s({"tokens":{}}), ~s({"tokens":{"refresh_token":""}})] do
        File.write!(r, bad)
        assert :invalid = AuthSync.sync(s, r)
        assert File.read!(s) == auth("rt-0", "2026-10-01T00:00:00Z")
      end
    end

    test "a missing run copy is :unchanged", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      assert :unchanged = AuthSync.sync(s, r)
    end

    test "writes through a symlinked source to the real file, keeping the link", %{
      source: s,
      run: r,
      tmp_dir: dir
    } do
      real = Path.join(dir, "dotfiles-auth.json")
      File.write!(real, auth("rt-0", "2026-10-01T00:00:00Z"))
      File.ln_s!(real, s)
      AuthSync.seed(s, r)
      File.write!(r, auth("rt-1", "2026-10-02T00:00:00Z"))

      assert :adopted = AuthSync.sync(s, r)

      assert {:ok, ^real} = File.read_link(s)
      assert File.read!(real) == auth("rt-1", "2026-10-02T00:00:00Z")
    end

    test "a run copy with no last_refresh never beats a dated source", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      File.write!(r, auth("rt-x", nil))

      assert :superseded = AuthSync.sync(s, r)
      assert File.read!(s) == auth("rt-0", "2026-10-01T00:00:00Z")
    end

    test "concurrent syncs of two runs leave the newest token", %{source: s, tmp_dir: dir} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))

      runs =
        for n <- 1..8 do
          r = Path.join(dir, "run#{n}/auth.json")
          File.mkdir_p!(Path.dirname(r))
          File.write!(r, auth("rt-#{n}", "2026-10-0#{min(n, 9)}T00:00:00Z"))
          r
        end

      runs |> Task.async_stream(&AuthSync.sync(s, &1), max_concurrency: 8) |> Stream.run()

      assert Jason.decode!(File.read!(s))["tokens"]["refresh_token"] == "rt-8"
    end
  end

  describe "pull/2" do
    test "a newer source replaces an unrotated run copy", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      AuthSync.seed(s, r)
      File.write!(s, auth("rt-2", "2026-10-03T00:00:00Z"))

      assert :pulled = AuthSync.pull(s, r)
      assert File.read!(r) == auth("rt-2", "2026-10-03T00:00:00Z")
    end

    test "an equal or newer run copy is left alone", %{source: s, run: r} do
      File.write!(s, auth("rt-0", "2026-10-01T00:00:00Z"))
      File.write!(r, auth("rt-1", "2026-10-02T00:00:00Z"))

      assert :unchanged = AuthSync.pull(s, r)
      assert File.read!(r) == auth("rt-1", "2026-10-02T00:00:00Z")
    end
  end
end
