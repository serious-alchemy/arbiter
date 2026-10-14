defmodule Arbiter.Worker.StateRedactionTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.State
  alias Arbiter.Worker.StateRedaction

  @secret "ghs_REDACTIONUNIT0123456789"

  describe "secrets/1" do
    test "the run's archive list and every session's redaction list, once each" do
      state = %State{
        archive_redact: [@secret, "tok-a"],
        claude_sessions: %{
          a: %{redact_values: ["tok-a", "tok-b"]},
          b: %{redact_values: nil},
          c: %{},
          d: :not_a_session
        }
      }

      assert Enum.sort(StateRedaction.secrets(state)) == Enum.sort([@secret, "tok-a", "tok-b"])
    end

    test "anything that is not a Worker state has none" do
      assert StateRedaction.secrets(nil) == []
      assert StateRedaction.secrets(%{meta: %{}}) == []
    end
  end

  describe "mask/2" do
    test "every binary, however nested, keeps its shape and loses the secret" do
      term = %{
        env: [{"ARB_GIT_TOKEN", @secret}, {"PATH", "/bin"}],
        request: %{git_secrets: %{"ARB_GIT_TOKEN" => @secret}},
        at: ~U[2026-10-14 00:00:00Z],
        line: "printed #{@secret} here",
        iodata: ["a", @secret | "tail " <> @secret],
        frame: {Arbiter.Worker, :handle_call, [:x, %{token: @secret}], [line: 1]}
      }

      masked = StateRedaction.mask(term, [@secret])

      assert :binary.match(:erlang.term_to_binary(masked), @secret) == :nomatch
      assert masked.env == [{"ARB_GIT_TOKEN", "[REDACTED]"}, {"PATH", "/bin"}]
      assert masked.request.git_secrets == %{"ARB_GIT_TOKEN" => "[REDACTED]"}
      assert masked.at == ~U[2026-10-14 00:00:00Z]
      assert masked.line == "printed [REDACTED] here"
      assert masked.iodata == ["a", "[REDACTED]" | "tail [REDACTED]"]

      assert {Arbiter.Worker, :handle_call, [:x, %{token: "[REDACTED]"}], [line: 1]} =
               masked.frame
    end

    test "a struct stays that struct" do
      masked = StateRedaction.mask(%State{task_id: @secret, meta: %{a: @secret}}, [@secret])
      assert %State{task_id: "[REDACTED]", meta: %{a: "[REDACTED]"}} = masked
    end

    test "with no secrets, the term is returned as it is" do
      term = %{a: "x", b: [1, {2, "y"}]}
      assert StateRedaction.mask(term, []) == term
    end
  end

  test "inspect of a Worker state masks the secrets it holds" do
    state = %State{
      archive_redact: [@secret],
      meta: %{claude_spawn: %{env: [{"ARB_GIT_TOKEN", @secret}]}}
    }

    shown = inspect(state, limit: :infinity, printable_limit: :infinity)
    refute String.contains?(shown, @secret)
    assert shown =~ ~s({"ARB_GIT_TOKEN", "[REDACTED]"})
    assert shown =~ "%Arbiter.Worker.State{"
  end
end
