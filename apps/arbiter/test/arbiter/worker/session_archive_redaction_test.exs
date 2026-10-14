defmodule Arbiter.Worker.SessionArchiveRedactionTest do
  @moduledoc """
  bd-akp9ae: the session JSONL a Worker archives when its run ends
  (`Arbiter.Worker.SessionArchive`) is scrubbed of every value the run's sessions were
  told to redact, a git token minted for the spawn among them, and not only of the
  workspace's stored secrets. An agent that printed its environment into its transcript
  must not leave the token in the durable archive.

  A real `Worker` and a real `ClaudeSession` spawn of a stand-in agent: it prints the
  stream's `init` event and writes its session JSONL with what `env` showed it.
  """
  use Arbiter.DataCase, async: false

  @moduletag :tmp_dir

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, GitCredential, SessionArchive}

  @http Arbiter.Worker.GitCredential.HTTP
  @token "ghs_ARCHIVEDMARKER0123456789"
  @sid "5d0f3c1a-7b8e-4a52-9c61-2e4f8a9b0c13"

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
        name: "sar-#{System.unique_integer([:positive])}",
        prefix: "sar",
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
      Ash.create(Issue, %{title: "archive redaction", workspace_id: ws.id, issue_type: :feature})

    %{ws: ws, issue: issue, tmp: tmp}
  end

  test "a git token the agent echoed into its transcript is scrubbed from the archive", ctx do
    config_dir = Path.join(ctx.tmp, "config")
    worktree = Path.join(ctx.tmp, "wt")
    File.mkdir_p!(worktree)

    # The stand-in agent: its transcript records what `env` showed it, then it says
    # which session it is and exits.
    script = """
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"
    printf '{"type":"user","message":{"content":"env: ARB_GIT_TOKEN=%s"},"sessionId":"#{@sid}"}\\n' "$ARB_GIT_TOKEN" > "$CLAUDE_CONFIG_DIR/projects/p/#{@sid}.jsonl"
    printf '{"type":"system","subtype":"init","session_id":"#{@sid}","model":"claude-test"}\\n'
    """

    {:ok, pid} = Worker.start(task_id: ctx.issue.id, repo: "tonic", workspace_id: ctx.ws.id)
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> ctx.issue.id)
    {:ok, plan} = GitCredential.plan(ctx.ws, "tonic", role: :implementer)

    assert {:ok, _port} =
             ClaudeSession.start(
               owner: pid,
               worktree_path: worktree,
               command: ["sh", "-c", script],
               env: [{"CLAUDE_CONFIG_DIR", config_dir}],
               provider: "claude",
               git_credential: plan
             )

    task_id = ctx.issue.id
    assert_receive {:worker_exited, ^task_id, 0}, 10_000
    # The transcript on disk holds the token, as the agent wrote it.
    assert File.read!(Path.join([config_dir, "projects", "p", @sid <> ".jsonl"])) =~ @token

    %{run_id: run_id} = Worker.state(pid)
    assert is_binary(run_id)
    :ok = Worker.fail(pid, :test_finished)

    assert {:ok, archived} = wait_for_archive(run_id)
    refute archived =~ @token
    assert archived =~ "ARB_GIT_TOKEN="
  end

  defp wait_for_archive(run_id, tries \\ 100) do
    case SessionArchive.read(run_id) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, _} when tries > 0 ->
        receive do
        after
          50 -> wait_for_archive(run_id, tries - 1)
        end

      error ->
        error
    end
  end
end
