defmodule Arbiter.Agents.HarnessVersionTest do
  @moduledoc """
  G18: the agent CLI version a host-local spawn records on its run, so a harness
  upgrade resets the subject's trust promotion clock. Fake CLIs are shell scripts
  in the test's own tmp dir.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Agents.HarnessVersion

  @moduletag :tmp_dir

  defp fake_cli(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "parse/1" do
    test "reads the version out of a CLI's --version answer" do
      assert HarnessVersion.parse("2.1.296 (Claude Code)\n") == "2.1.296"
      assert HarnessVersion.parse("codex-cli 0.50.0") == "0.50.0"
      assert HarnessVersion.parse("agy version v1.2.16-beta.1\nbuilt today") == "1.2.16-beta.1"
      assert HarnessVersion.parse("no version here") == nil
      assert HarnessVersion.parse("") == nil
    end
  end

  describe "host/2" do
    test "asks the binary once per build and caches the answer", %{tmp_dir: dir} do
      calls = Path.join(dir, "calls")
      bin = fake_cli(dir, "fake-cli", "echo x >> #{calls}; echo '9.8.7 (Fake CLI)'")

      assert HarnessVersion.host("claude", executable: bin, probe: true) == "9.8.7"
      assert HarnessVersion.host("claude", executable: bin, probe: true) == "9.8.7"
      assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 1

      # An upgrade replaces the binary: it is asked again.
      File.rm!(bin)
      fake_cli(dir, "fake-cli", "echo x >> #{calls}; echo '10.0.0 (Fake CLI)'")
      assert HarnessVersion.host("claude", executable: bin, probe: true) == "10.0.0"
    end

    test "a CLI that does not answer in time is given up on", %{tmp_dir: dir} do
      bin = fake_cli(dir, "slow-cli", "sleep 5; echo 1.0.0")

      {micros, version} =
        :timer.tc(fn ->
          HarnessVersion.host("claude", executable: bin, probe: true, timeout_ms: 200)
        end)

      assert version == nil
      assert micros < 3_000_000
    end

    test "is nil when probing is off, the binary is missing, or the provider is unknown", %{
      tmp_dir: dir
    } do
      bin = fake_cli(dir, "cli", "echo 1.2.3")

      assert HarnessVersion.host("claude", executable: bin, probe: false) == nil
      assert HarnessVersion.host("claude", executable: Path.join(dir, "nope"), probe: true) == nil
      assert HarnessVersion.host("not-a-harness", probe: true) == nil
    end
  end
end
