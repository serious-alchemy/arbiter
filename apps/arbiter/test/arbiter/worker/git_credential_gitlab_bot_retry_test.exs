defmodule Arbiter.Worker.GitCredentialGitlabBotRetryTest do
  @moduledoc """
  Issue #1305: the `gitlab_bot_token` guard stays fail-closed, but a verification
  that merely could not be answered (timeout / transport / 5xx / 429) is retried with
  bounded backoff and a recent success is reused for a short TTL, while a rejection
  (401/403 on the token check) refuses at once and is never cached.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.GitCredential.GitlabBot
  alias Arbiter.Worker.GitCredential.Material

  @http Arbiter.Worker.GitCredential.HTTP
  @bot "glpat-bot-retry-0123456789"
  @self "/api/v4/personal_access_tokens/self"

  setup do
    old = Application.get_env(:arbiter, :gitlab_bot_verify)
    GitlabBot.clear_cache()

    on_exit(fn ->
      GitlabBot.clear_cache()

      if old,
        do: Application.put_env(:arbiter, :gitlab_bot_verify, old),
        else: Application.delete_env(:arbiter, :gitlab_bot_verify)
    end)

    :ok
  end

  defp config(opts), do: Application.put_env(:arbiter, :gitlab_bot_verify, opts)

  defp workspace(secret \\ @bot) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "glr-#{System.unique_integer([:positive])}",
        prefix: "gr",
        config: %{
          "git_credentials" => %{
            "repos" => %{
              "tonic" => %{
                "kind" => "gitlab_bot_token",
                "secret" => "GL_BOT",
                "host" => "gitlab.com"
              }
            }
          }
        },
        secrets: %{"GL_BOT" => secret}
      })

    ws
  end

  defp materialize(ws) do
    {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer, guarded?: true)

    GitCredential.materialize(plan, ws,
      remote: "acme/tonic",
      req_options: [plug: {Req.Test, @http}]
    )
  end

  defp in_days(n), do: Date.utc_today() |> Date.add(n) |> Date.to_iso8601()

  defp good(conn) do
    case conn.request_path do
      @self ->
        Req.Test.json(conn, %{
          "active" => true,
          "scopes" => ["read_api", "read_repository", "write_repository"],
          "expires_at" => in_days(60)
        })

      "/api/v4/projects" ->
        Req.Test.json(conn, [%{"path_with_namespace" => "acme/tonic"}])
    end
  end

  # The token check fails `failures` times (`:timeout` or an HTTP status), then
  # answers. Returns a counter of token-check requests.
  defp stub_flaky(failures, failure \\ :timeout) do
    counter = :counters.new(1, [])

    Req.Test.stub(@http, fn conn ->
      if conn.request_path == @self do
        :counters.add(counter, 1, 1)

        cond do
          :counters.get(counter, 1) > failures -> good(conn)
          failure == :timeout -> Req.Test.transport_error(conn, :timeout)
          true -> Plug.Conn.send_resp(conn, failure, "")
        end
      else
        good(conn)
      end
    end)

    counter
  end

  defp stub_status(status) do
    counter = :counters.new(1, [])

    Req.Test.stub(@http, fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, status, "")
    end)

    counter
  end

  test "a timeout is retried with backoff and the dispatch proceeds" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 0)
    counter = stub_flaky(2)

    assert {:ok, %Material{kind: :gitlab_bot_token}} = materialize(workspace())
    assert :counters.get(counter, 1) == 3
  end

  test "a 5xx and a 429 are retried too" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 0)

    for status <- [503, 429] do
      stub_flaky(1, status)
      assert {:ok, _} = materialize(workspace())
    end
  end

  test "retries are bounded: still unverifiable after the last attempt" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 0)
    counter = stub_flaky(100)

    assert {:error, {:git_credential_bot_token_unverifiable, _}} = materialize(workspace())
    assert :counters.get(counter, 1) == 3
  end

  test "a rejection (401/403) refuses at once: no retry, no delivery" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 60_000)

    for status <- [401, 403] do
      counter = stub_status(status)

      assert {:error, {:git_credential_bot_token_refused, {:rejected, ^status}} = error} =
               materialize(workspace())

      assert :counters.get(counter, 1) == 1
      refute GitCredential.format_error(error) =~ "retrying"
      refute inspect(error) =~ @bot
    end
  end

  test "a success is reused within the TTL; a rejection is never cached as success" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 60_000)
    ws = workspace()

    Req.Test.stub(@http, &good/1)
    assert {:ok, _} = materialize(ws)

    # GitLab now rejects, but the check passed moments ago: no call is made.
    counter = stub_status(403)
    assert {:ok, _} = materialize(ws)
    assert :counters.get(counter, 1) == 0

    # With the TTL gone the next dispatch re-checks and the rejection refuses...
    config(backoff_ms: [0, 0], cache_ttl_ms: 0)
    assert {:error, {:git_credential_bot_token_refused, {:rejected, 403}}} = materialize(ws)

    # ...and a rejection leaves nothing behind that a later check could reuse.
    GitlabBot.clear_cache()
    config(backoff_ms: [0, 0], cache_ttl_ms: 60_000)
    stub_status(403)
    assert {:error, {:git_credential_bot_token_refused, {:rejected, 403}}} = materialize(ws)
  end

  test "the cache is keyed on the token: a rotated token is checked afresh" do
    config(backoff_ms: [0, 0], cache_ttl_ms: 60_000)
    Req.Test.stub(@http, &good/1)
    assert {:ok, _} = materialize(workspace())

    stub_status(403)

    assert {:error, {:git_credential_bot_token_refused, {:rejected, 403}}} =
             materialize(workspace(@bot <> "-rotated"))
  end

  test "the wording distinguishes rejected from could-not-verify" do
    unverifiable = GitCredential.format_error({:git_credential_bot_token_unverifiable, "x"})
    rejected = GitCredential.format_error({:git_credential_bot_token_refused, {:rejected, 403}})

    assert unverifiable =~ "could not be verified"
    assert unverifiable =~ "retrying"
    assert rejected =~ "rejected"
    assert rejected =~ "403"
    refute rejected =~ "retrying"
  end

  test "only a transient unverifiable state is a deferral" do
    assert GitCredential.bot_guard_transient?(
             {:claude_start_failed, {:git_credential_bot_token_unverifiable, "x"}}
           )

    refute GitCredential.bot_guard_transient?(
             {:claude_start_failed, {:git_credential_bot_token_refused, :expired}}
           )
  end
end
