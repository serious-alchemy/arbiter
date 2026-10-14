defmodule Arbiter.Worker.StatusRedactionTest do
  @moduledoc """
  bd-akp9ae: a Worker's state holds every value its sessions were told to redact (a git
  token minted for the spawn, the provider token, the workspace's secrets): in each
  session's redaction list, in the spawn it keeps for a re-open, and in the run's own
  archive list. A crash report prints the state, as does `:sys.get_status/1`, so both
  mask those values wherever they appear in it.

  A real `Worker` and a real `ClaudeSession` spawn of a stand-in agent, given a GitHub
  App repo's installation token (minted here, against a stub).
  """
  use Arbiter.DataCase, async: false

  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, GitCredential}

  @http Arbiter.Worker.GitCredential.HTTP
  @token "ghs_STATUSMARKER0123456789"
  @oauth "sk-ant-oat01-STATUSOAUTHMARKER-3c1"

  setup %{tmp_dir: tmp} do
    put_app_env(:arbiter, :output_log_root, Path.join(tmp, "logs"))
    put_app_env(:arbiter, :git_credential_req_options, plug: {Req.Test, @http})
    Req.Test.set_req_test_to_shared(%{async: false})

    Req.Test.stub(@http, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"token" => @token, "expires_at" => "2099-01-01T00:00:00Z"})
    end)

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "wsr-#{System.unique_integer([:positive])}",
        prefix: "wsr",
        config: %{
          "git_credentials" => %{
            "repos" => %{
              "tonic" => %{
                "kind" => "github_app",
                "app_id" => "42",
                "installation_id" => "7",
                "private_key_secret" => "APP_KEY",
                "remote" => "acme/tonic"
              }
            }
          }
        },
        secrets: %{"APP_KEY" => pem}
      })

    {:ok, issue} =
      Ash.create(Issue, %{title: "status redaction", workspace_id: ws.id, issue_type: :feature})

    {:ok, pid} = Worker.start(task_id: issue.id, repo: "tonic", workspace_id: ws.id)
    {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer)
    worktree = Path.join(tmp, "wt")
    File.mkdir_p!(worktree)

    # The stand-in agent says which session it is, then waits for its stdin to close.
    script = ~S"""
    printf '{"type":"system","subtype":"init","session_id":"s1","model":"claude-test"}\n'
    while read -r _; do :; done
    """

    assert {:ok, _port} =
             ClaudeSession.start(
               owner: pid,
               worktree_path: worktree,
               command: ["sh", "-c", script],
               env: [{"CLAUDE_CODE_OAUTH_TOKEN", @oauth}],
               provider: "claude",
               git_credential: plan
             )

    %{pid: pid}
  end

  # The assertions below take a message, so a failure never prints the state or the
  # log: both hold the environment's own provider token too.

  test "the state holds the tokens; its status and its inspect name neither", %{pid: pid} do
    # What the masking has to cover: the tokens really are in the state.
    state = :sys.get_state(pid)
    assert holds?(state, @token), "the git token is not in the state"
    assert holds?(state, @oauth), "the provider token is not in the state"

    # The status, as a term (what a handler formatting raw terms prints) and inspected.
    status = :sys.get_status(pid)
    refute holds?(status, @token), "the status holds the git token"
    refute holds?(status, @oauth), "the status holds the provider token"
    shown = inspect(status, limit: :infinity, printable_limit: :infinity)
    refute String.contains?(shown, @token), "the status names the git token"
    assert String.contains?(shown, Arbiter.Redaction.placeholder()), "nothing was masked"

    # The state inspected anywhere else (a log line).
    shown = inspect(state, limit: :infinity, printable_limit: :infinity)
    refute String.contains?(shown, @token), "inspect names the git token"
    refute String.contains?(shown, @oauth), "inspect names the provider token"
  end

  test "a crash report names neither token", %{pid: pid} do
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(pid, :not_a_worker_call))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      end)

    # The report was written, with the state it printed (here as the arguments of the
    # frame that raised).
    assert String.contains?(log, "terminating"), "no crash report was logged"
    assert String.contains?(log, "%Arbiter.Worker.State{"), "the report printed no state"
    assert String.contains?(log, Arbiter.Redaction.placeholder()), "the report masked nothing"
    refute String.contains?(log, @token), "the crash report names the git token"
    refute String.contains?(log, @oauth), "the crash report names the provider token"
  end

  # Whether `term` holds `value` anywhere in it, as stored (not as inspected).
  defp holds?(term, value), do: :binary.match(:erlang.term_to_binary(term), value) != :nomatch
end
