defmodule Arbiter.Agents.PreflightTest do
  # async: false — the CLAUDE_CODE_OAUTH_TOKEN fallback tests below mutate the
  # process-global OS environment (bd-2zigo1).
  use ExUnit.Case, async: false

  # No Ecto sandbox here, so ConfigDir's workspace-less read of the
  # install-wide account credential can't reach the database and degrades to
  # "no credential". Capture any log so the run stays readable (logs still
  # surface on failure).
  @moduletag :capture_log

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Preflight

  describe "check/2 with a probe_command override" do
    test "a clean ping authenticates → :ok" do
      assert :ok =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "echo pong; exit 0"],
                 probe_env: []
               )
    end

    test "a 401 probe → {:error, :auth_expired} with re-auth remediation" do
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   "echo 'API Error: 401 Invalid authentication credentials'; exit 1"
                 ],
                 probe_env: []
               )

      assert reason.category == :auth_expired
      assert reason.remediation =~ "Re-authenticate"
    end

    test "a clean exit that still printed an auth error is refused" do
      # Some CLIs print the error but exit 0; the output classifier must catch it.
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "echo 'invalid authentication credentials'; exit 0"],
                 probe_env: []
               )

      assert reason.category == :auth_expired
    end

    test "a missing executable is refused (not a silent pass)" do
      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["/no/such/cli/here", "--print", "ping"],
                 probe_env: []
               )

      assert reason.category == :crashed
      assert reason.summary =~ "not found"
    end

    # bd-svczq4: a hung probe no longer *refuses* by default — a timeout is the
    # one outcome that says nothing about the credentials, and a nondeterministic
    # probe blocking valid work is what this ticket was filed about. It reports
    # `{:warn, ...}` with its own category so the caller can log and proceed; see
    # `Arbiter.Agents.PreflightProbeTest` for the `on_timeout: :refuse` lever.
    test "a hung probe warns with a pre-flight-specific reason, not a worker stall" do
      assert {:warn, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 5"],
                 probe_env: [],
                 timeout_ms: 80
               )

      assert reason.category == :preflight_timeout
      refute reason.category == :stalled
    end
  end

  describe "check/2 and a server-env CLAUDE_CODE_OAUTH_TOKEN (bd-2zigo1; inert since P13)" do
    setup do
      prev_oauth_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        Claude.Config.clear()

        case prev_oauth_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    # P13 (bd-9gqj8e): the server env is no longer a credential source — the
    # probe authenticates from the install-wide provider account credential
    # (`arbiter/accounts/legacy_chain_removed_test.exs` drives that against a
    # real database and a stub `claude`). What this file can pin without one
    # is the negative: a server-env token neither reaches `spawn_env/1` nor
    # the probe's child process.
    test "Claude.spawn_env/1 never exports a server-env token" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

      assert {"CLAUDE_CODE_OAUTH_TOKEN", false} in Claude.spawn_env([])
      refute {"CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token"} in Claude.spawn_env([])
    end

    test "a server-env token does not reach the probe: the child sees it unset" do
      # `Port.open`'s `{:env, ...}` extends the BEAM's own environment, so a
      # token set with `System.put_env/2` would reach the spawned `sh` unless
      # `spawn_env/1`'s explicit `{..., false}` unsets it — which is exactly
      # what this asserts.
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "test-oauth-session-token")

      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   ~s(if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then echo pong; exit 0; else echo '401 invalid authentication credentials'; exit 1; fi)
                 ]
               )

      assert reason.category == :auth_expired
    end

    test "probe fails without CLAUDE_CODE_OAUTH_TOKEN or an api_key (control case)" do
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: [
                   "sh",
                   "-c",
                   ~s(if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then echo pong; exit 0; else echo '401 invalid authentication credentials'; exit 1; fi)
                 ]
               )

      assert reason.category == :auth_expired
    end
  end

  describe "check/2 probe env sourcing (bd-2zigo1)" do
    defmodule SpawnEnvAdapter do
      @moduledoc false
      def spawn_env(_opts), do: [{"ARB_PROBE_SENTINEL", "from-spawn-env"}]
    end

    test "the probe env comes from the adapter's spawn_env/1, not the BEAM's inherited env" do
      # ARB_PROBE_SENTINEL is never set on the BEAM process itself, so the
      # only way the spawned `sh` can see it is if `Preflight.check/2` actually
      # calls `SpawnEnvAdapter.spawn_env/1` and threads its output into the
      # port's env (`safe_spawn_env/2`, preflight.ex:89) — unlike the
      # `System.put_env/2` scenario above, there's no ambient inheritance to
      # produce a false pass here.
      refute System.get_env("ARB_PROBE_SENTINEL")

      assert :ok =
               Preflight.check(SpawnEnvAdapter,
                 probe_command: ["sh", "-c", ~s(test "$ARB_PROBE_SENTINEL" = from-spawn-env)]
               )
    end
  end

  describe "check/2 with direct auth_probe/1 (bd-2r42bq)" do
    defmodule DirectProbeAdapter do
      @moduledoc false
      def provider, do: "directprobe"

      def auth_probe(opts) do
        case Keyword.get(opts, :status) do
          :fail ->
            {:error,
             %Arbiter.Worker.StopReason{
               category: :auth_expired,
               summary: "Direct probe auth expired",
               remediation: "Re-login"
             }}

          :skip ->
            :skipped

          _ ->
            :ok
        end
      end

      def auth_probe_argv(_opts), do: {:ok, ["sh", "-c", "echo fallback; exit 0"]}
    end

    test "calls auth_probe/1 directly and returns :ok without spawning OS process" do
      assert :ok = Preflight.check(DirectProbeAdapter, status: :ok)
    end

    test "returns {:error, reason} directly from auth_probe/1" do
      assert {:error, reason} = Preflight.check(DirectProbeAdapter, status: :fail)
      assert reason.category == :auth_expired
      assert reason.summary =~ "Direct probe auth expired"
    end

    test "falls back to auth_probe_argv/1 when auth_probe/1 returns :skipped" do
      assert :ok = Preflight.check(DirectProbeAdapter, status: :skip)
    end

    test "probe_command override bypasses auth_probe/1" do
      assert {:error, reason} =
               Preflight.check(DirectProbeAdapter,
                 status: :ok,
                 probe_command: ["sh", "-c", "echo '401 Unauthorized'; exit 1"],
                 probe_env: []
               )

      assert reason.category == :auth_expired
    end
  end

  describe "check/2 with an unprobeable adapter" do
    defmodule NoProbeAdapter do
      # An adapter that doesn't implement auth_probe_argv/1.
      def provider, do: "noprobe"
    end

    test "returns :skipped — never blocks on an absent probe" do
      assert :skipped = Preflight.check(NoProbeAdapter, [])
    end
  end
end
