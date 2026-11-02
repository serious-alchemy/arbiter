defmodule Arbiter.Mergers.CiSkipTest do
  @moduledoc """
  bd-4y9dno — the forge-specific halves of the merge train's phase 2: how an
  adapter says "do not start a pipeline for this push" (`ci_skip_mechanism/1`)
  and how it starts the one the head needs (`trigger_pipeline/2`). Adapter stubs
  at the HTTP layer.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.CiSkip
  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Test.StubMerger

  @gl_env "CISKIP_GITLAB_TOKEN"
  @gh_env "CISKIP_GITHUB_TOKEN"

  setup do
    System.put_env(@gl_env, "gl-token")
    System.put_env(@gh_env, "gh-token")

    Gitlab.Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@gl_env}",
      "default_target_branch" => "main"
    })

    Github.Config.put_active(%{
      "owner" => "octo",
      "repo" => "widget",
      "credentials_ref" => "env:#{@gh_env}",
      "default_target_branch" => "main"
    })

    for {:gitlab_project_path, _, _} = key <- Enum.map(:persistent_term.get(), &elem(&1, 0)) do
      :persistent_term.erase(key)
    end

    StubMerger.reset()

    on_exit(fn ->
      Gitlab.Config.clear()
      Github.Config.clear()
      System.delete_env(@gl_env)
      System.delete_env(@gh_env)
    end)

    :ok
  end

  describe "mechanism/2" do
    test "GitLab skips with a push option" do
      assert CiSkip.mechanism(Gitlab, %{}) == {:push_option, "ci.skip"}
    end

    test "GitHub skips with a commit marker, but only when a dispatch workflow is configured" do
      assert CiSkip.mechanism(Github, %{workflow: "ci.yml"}) == {:commit_marker, "[skip ci]"}
      # without one the head's pipeline could not be started again: never skip
      assert CiSkip.mechanism(Github, %{}) == nil
      assert CiSkip.mechanism(Github, %{workflow: ""}) == nil
    end

    test "an adapter without the callback has no mechanism" do
      assert CiSkip.mechanism(Arbiter.Mergers.Direct, %{}) == nil
      assert CiSkip.mechanism(nil, %{}) == nil
    end
  end

  describe "trigger/3" do
    test "GitLab creates a merge request pipeline" do
      test = self()

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:gl, conn.method, conn.request_path, raw})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 501, "web_url" => "https://gl/p/501"})
      end)

      assert {:ok, %{run_id: 501, url: "https://gl/p/501"}} = CiSkip.trigger(Gitlab, "!42", %{})
      assert_received {:gl, "POST", "/api/v4/projects/12345/merge_requests/42/pipelines", _}
    end

    test "GitLab reports a refused pipeline as an error" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "message" => %{"base" => ["Pipeline will not run for the selected trigger"]}
        })
      end)

      assert {:error, _} = CiSkip.trigger(Gitlab, "!42", %{})
    end

    test "GitHub dispatches the configured workflow on the PR's head branch" do
      test = self()

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/octo/widget/pulls/42"} ->
            Req.Test.json(conn, %{"head" => %{"sha" => "abc", "ref" => "feature/x"}})

          {"POST", "/repos/octo/widget/actions/workflows/ci.yml/dispatches"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:dispatch, Jason.decode!(raw)})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:ok, %{mode: :workflow_dispatch}} =
               CiSkip.trigger(Github, "#42", %{workflow: "ci.yml"})

      assert_received {:dispatch, %{"ref" => "feature/x"}}
    end

    test "GitHub without a workflow cannot trigger" do
      assert {:error, _} = CiSkip.trigger(Github, "#42", %{})
    end

    test "an adapter with no trigger is unsupported" do
      assert CiSkip.trigger(Arbiter.Mergers.Direct, "x", %{}) == {:error, :unsupported}
    end

    test "the test stub records the trigger" do
      assert {:ok, _} = CiSkip.trigger(StubMerger, "!1", %{})
      assert [{"!1", %{}}] = StubMerger.pipeline_triggers()
    end
  end
end
