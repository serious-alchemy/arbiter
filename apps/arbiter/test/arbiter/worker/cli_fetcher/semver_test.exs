defmodule Arbiter.Worker.CliFetcher.SemverTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.CliFetcher.Semver

  describe "stable?/1" do
    test "accepts plain x.y.z" do
      assert Semver.stable?("2.1.310")
      assert Semver.stable?("0.164.0")
    end

    test "refuses prereleases, platform suffixes, build metadata and junk" do
      refute Semver.stable?("0.165.0-alpha.1")
      refute Semver.stable?("0.164.0-linux-x64")
      refute Semver.stable?("1.0.0-rc.1")
      refute Semver.stable?("1.0.0+build5")
      refute Semver.stable?("1.0")
      refute Semver.stable?("v1.0.0")
      refute Semver.stable?("1.0.0\n")
      refute Semver.stable?(nil)
    end
  end

  describe "newest_stable/1" do
    test "picks the numerically highest stable version, never a prerelease" do
      versions = ["0.9.0", "0.10.0", "0.164.0-linux-x64", "0.165.0-alpha.1", "0.2.0"]
      assert Semver.newest_stable(versions) == "0.10.0"
    end

    test "nil when there is no stable version" do
      assert Semver.newest_stable(["1.0.0-rc.1"]) == nil
      assert Semver.newest_stable([]) == nil
    end
  end

  test "newer?/2 compares numerically" do
    assert Semver.newer?("0.10.0", "0.9.9")
    refute Semver.newer?("0.9.9", "0.10.0")
    refute Semver.newer?("1.0.0", "1.0.0")
  end
end
