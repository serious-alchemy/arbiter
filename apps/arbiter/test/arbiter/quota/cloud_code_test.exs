defmodule Arbiter.Quota.CloudCodeTest do
  # async: true — each test stubs its own `agy_usage_probe`, so there is no
  # shared mutable state to race on. The upstream Gemini CLI fetch (`gemini/1`)
  # is gone with the `gemini_cli` provider (bd-ac53wz).
  use ExUnit.Case, async: true

  alias Arbiter.Quota.CloudCode

  # Stub `agy_usage_probe` so tests never shell out to a real `agy` binary
  # that may happen to be installed on the machine running the suite.
  defp antigravity_opts(probe_result) do
    [agy_usage_probe: fn -> probe_result end]
  end

  defp agy_usage_body(groups) do
    %{"command" => %{"data" => %{"groups" => groups}}}
  end

  describe "antigravity/1 (bd-d7hmqn: agy --output-format json --print /usage)" do
    test "flattens both groups and both windows into per-{group,window} model rows" do
      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.4, "reset_time" => "1782250684"},
              %{"window" => "5h", "remaining_fraction" => 0.75, "reset_time" => "1782250684"}
            ]
          },
          %{
            "name" => "Claude and GPT models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 1.0, "reset_time" => "1782250684"},
              %{"window" => "5h", "remaining_fraction" => 1.0, "reset_time" => "1782250684"}
            ]
          }
        ])

      snap = CloudCode.antigravity(antigravity_opts({:ok, body}))

      assert snap.provider == "antigravity"
      assert snap.message == nil
      assert snap.auth_expired == false
      assert length(snap.models) == 4

      by_id = Map.new(snap.models, &{&1.model_id, &1})
      gemini_weekly = by_id["gemini_models_weekly"]
      assert gemini_weekly.remaining_percentage == 40.0
      assert gemini_weekly.display_name == "Gemini Models (weekly)"
      assert gemini_weekly.reset_at == "2026-06-23T21:38:04.000Z"

      gemini_5h = by_id["gemini_models_5h"]
      assert gemini_5h.remaining_percentage == 75.0

      claude_weekly = by_id["claude_and_gpt_models_weekly"]
      assert claude_weekly.remaining_percentage == 100.0
      claude_5h = by_id["claude_and_gpt_models_5h"]
      assert claude_5h.remaining_percentage == 100.0
    end

    test "does not invert remaining_fraction — a nearly-empty bucket stays low, not high" do
      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [%{"window" => "5h", "remaining_fraction" => 0.02, "reset_time" => nil}]
          }
        ])

      snap = CloudCode.antigravity(antigravity_opts({:ok, body}))
      assert [model] = snap.models
      assert model.remaining_percentage == 2.0
      assert model.used == 980
    end

    test "degrades to a clear message when the agy binary is not on PATH" do
      snap =
        CloudCode.antigravity(agy_cmd: "definitely-not-a-real-agy-binary-xyz-#{__ENV__.line}")

      refute is_nil(snap)
      assert snap.provider == "antigravity"
      assert snap.models == []
      assert snap.message =~ "not installed"
    end

    test "degrades to a clear message when agy exits non-zero (not authenticated)" do
      snap = CloudCode.antigravity(antigravity_opts({:error, {:exit, 1}}))

      assert snap.models == []
      assert snap.message =~ "not authenticated"
      # bd-1fpjgx: the one outcome CloudProbe treats as a credential-expiry
      # signal — see the moduledoc's "Flow — Antigravity" and CloudProbe's own
      # "Credential-expiry signals" section.
      assert snap.auth_expired == true
    end

    test "degrades to a clear message on a subprocess timeout" do
      snap = CloudCode.antigravity(antigravity_opts({:error, :timeout}))

      assert snap.models == []
      assert snap.message =~ "did not respond in time"
      assert snap.auth_expired == false
    end

    test "degrades to a clear message on malformed JSON" do
      snap = CloudCode.antigravity(antigravity_opts({:error, :malformed}))

      assert snap.models == []
      assert snap.message =~ "unexpected data"
      assert snap.auth_expired == false
    end

    test "degrades to a clear message when the decoded JSON has no usage groups" do
      snap = CloudCode.antigravity(antigravity_opts({:ok, %{"command" => %{}}}))

      assert snap.models == []
      assert snap.message =~ "unexpected data"
    end

    test "never returns nil, unlike the old stored-token probe" do
      for result <- [
            {:ok, agy_usage_body([])},
            {:error, :not_installed},
            {:error, :timeout},
            {:error, {:exit, 1}},
            {:error, :malformed}
          ] do
        refute is_nil(CloudCode.antigravity(antigravity_opts(result)))
      end
    end
  end

  describe "antigravity/1 real shell-out path (agy_cmd, no agy_usage_probe stub)" do
    # These exercise `agy_usage_default/1` / `shell_out_agy_usage/2` for real —
    # `agy_cmd` points at a real executable instead of stubbing
    # `agy_usage_probe`, so the `System.find_executable/1` resolution, the
    # `sh -c` argv construction, and the exit-status / output-file handling
    # all actually run.
    test "a 0-exit executable with no parseable output degrades to the malformed-JSON message" do
      snap = CloudCode.antigravity(agy_cmd: "true")

      refute is_nil(snap)
      assert snap.message =~ "unexpected data"
    end

    test "a nonzero-exit executable is reported as not authenticated" do
      snap = CloudCode.antigravity(agy_cmd: "false")

      assert snap.models == []
      assert snap.message =~ "not authenticated"
    end

    test "an executable name that does not resolve is reported as not installed" do
      snap = CloudCode.antigravity(agy_cmd: "definitely-not-a-real-agy-binary-xyz")

      assert snap.models == []
      assert snap.message =~ "not installed"
    end

    test "the real subprocess result is memoized so repeated calls don't re-exec agy" do
      dir = System.tmp_dir!()
      script = Path.join(dir, "agy_counter_#{System.unique_integer([:positive])}.sh")
      counter = script <> ".count"

      File.write!(script, """
      #!/bin/sh
      echo x >> "#{counter}"
      echo '{"command":{"data":{"groups":[]}}}'
      exit 0
      """)

      File.chmod!(script, 0o755)

      on_exit(fn ->
        File.rm(script)
        File.rm(counter)
      end)

      opts = [agy_cmd: script]

      refute is_nil(CloudCode.antigravity(opts))
      refute is_nil(CloudCode.antigravity(opts))

      {:ok, contents} = File.read(counter)
      assert String.trim(contents) |> String.split("\n") |> length() == 1
    end

    # bd-au2xhz: 53 of 117 daily-timeout runs had already finished `/usage`
    # (its output sitting in the temp file) before the `timeout` coreutil's
    # SIGTERM/SIGKILL caught a lingering child and the shell reported 124/137.
    test "output already written before a 124/137 kill is read as a real success, not a timeout" do
      dir = System.tmp_dir!()
      script = Path.join(dir, "agy_lingers_#{System.unique_integer([:positive])}.sh")

      File.write!(script, """
      #!/bin/sh
      echo '{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"window":"weekly","remaining_fraction":0.25,"reset_time":"1782250684"}]}]}}}'
      sleep 5
      """)

      File.chmod!(script, 0o755)
      on_exit(fn -> File.rm(script) end)

      snap = CloudCode.antigravity(agy_cmd: script, agy_probe_timeout: 500)

      refute snap.message
      assert length(snap.models) == 1
    end

    test "a genuine timeout with no output logs a warning naming the elapsed time" do
      dir = System.tmp_dir!()
      script = Path.join(dir, "agy_hangs_#{System.unique_integer([:positive])}.sh")

      File.write!(script, """
      #!/bin/sh
      sleep 5
      """)

      File.chmod!(script, 0o755)
      on_exit(fn -> File.rm(script) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          snap = CloudCode.antigravity(agy_cmd: script, agy_probe_timeout: 500)
          assert snap.message =~ "did not respond in time"
        end)

      assert log =~ "timed out"
      assert log =~ "ms"
    end
  end
end
