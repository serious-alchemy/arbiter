defmodule Arbiter.Mergers.GitlabTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.{Config, Error}

  @host "gitlab.com"
  @project 12_345
  @iid 42
  @ref "!42"
  @env_var "GTE_GITLAB_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => @host,
      "project_id" => @project,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main",
      "default_reviewers" => [7]
    })

    for {:gitlab_project_path, _, _} = key <- Enum.map(:persistent_term.get(), &elem(&1, 0)) do
      :persistent_term.erase(key)
    end

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fun)

  defp base_path, do: "/api/v4/projects/#{@project}/merge_requests"

  describe "open/4" do
    test "201: POSTs the MR and returns {:ok, mr_ref}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == base_path()
        assert ["test-gitlab-token"] = Plug.Conn.get_req_header(conn, "private-token")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["source_branch"] == "feature/bd-9bn4n9"
        assert decoded["target_branch"] == "main"
        assert decoded["title"] == "Implement GitLab merger"
        assert decoded["reviewer_ids"] == [7]
        assert decoded["labels"] == "worker,merger"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "iid" => @iid,
          "web_url" => "https://gitlab.com/x/-/merge_requests/42"
        })
      end)

      assert {:ok, @ref} =
               Gitlab.open("feature/bd-9bn4n9", "Implement GitLab merger", "body", %{
                 labels: ["worker", "merger"]
               })
    end

    test "honours an explicit :target_branch and :reviewer_ids over the config defaults" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["target_branch"] == "develop"
        assert decoded["reviewer_ids"] == [1, 2]

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      assert {:ok, @ref} =
               Gitlab.open("feature/x", "t", "d", %{
                 target_branch: "develop",
                 reviewer_ids: [1, 2]
               })
    end

    test "422: returns {:error, %Error{kind: :validation_failed}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => ["Source branch does not exist"]})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Gitlab.open("nope", "t", "d", %{})
    end

    test "422 'already exists': adopts the existing open MR" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => [
                "Another open merge request already exists for this source branch: feature/bd-4i8z1r"
              ]
            })

          "GET" ->
            assert conn.request_path == base_path()
            assert conn.query_string =~ "state=opened"
            assert conn.query_string =~ "source_branch="

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"iid" => @iid, "state" => "opened"}])
        end
      end)

      assert {:ok, @ref} = Gitlab.open("feature/bd-4i8z1r", "Fix something", "body", %{})
    end

    test "422 'already exists' but listing returns empty: returns conflict error" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => ["Another open merge request already exists for this source branch"]
            })

          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([])
        end
      end)

      assert {:error, %Error{kind: :conflict}} = Gitlab.open("feature/x", "t", "d", %{})
    end

    test "422 'already exists' with message as string instead of list: adopts existing MR" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "Another open merge request already exists for this source branch"
            })

          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"iid" => @iid, "state" => "opened"}])
        end
      end)

      assert {:ok, @ref} = Gitlab.open("feature/x", "t", "d", %{})
    end

    test "409 'already exists' (bd-dm2t5d): adopts the existing open MR" do
      stub(fn conn ->
        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_status(409)
            |> Req.Test.json(%{
              "message" => [
                "Another open merge request already exists for this source branch: !4"
              ]
            })

          "GET" ->
            assert conn.request_path == base_path()
            assert conn.query_string =~ "state=opened"
            assert conn.query_string =~ "source_branch="

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"iid" => @iid, "state" => "opened"}])
        end
      end)

      assert {:ok, @ref} = Gitlab.open("feature/x", "t", "d", %{})
    end

    test "409 unrelated conflict: returns {:error, %Error{kind: :conflict}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"message" => "Resource is locked"})
      end)

      assert {:error, %Error{kind: :conflict, status: 409}} =
               Gitlab.open("feature/x", "t", "d", %{})
    end

    test "when repo_path is provided but branch doesn't exist: returns git_push_failed error" do
      # Use a branch name that likely doesn't exist on the remote
      bad_branch = "feature/nonexistent-branch-#{System.unique_integer()}"
      repo_dir = File.cwd!()

      # Don't stub the HTTP call — we should fail at the git push step before reaching it
      result = Gitlab.open(bad_branch, "Test", "desc", %{repo_path: repo_dir})

      # The push should fail because the branch doesn't exist
      assert {:error, %Error{kind: :git_push_failed, message: msg}} = result
      assert String.contains?(msg, "Failed to push branch")
    end

    test "when repo_path points to non-existent dir: returns git_push_failed error" do
      stub(fn conn -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"iid" => @iid}) end)

      non_existent = "/tmp/does_not_exist_#{System.unique_integer()}/repo"

      assert {:error, %Error{kind: :git_push_failed, message: msg}} =
               Gitlab.open("feature/x", "t", "d", %{repo_path: non_existent})

      assert String.contains?(msg, "Failed to push branch")
    end

    test "when repo_path is not provided: skips push and creates MR normally" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == base_path()

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      # Call open without repo_path — should skip push and create MR
      assert {:ok, @ref} =
               Gitlab.open("feature/x", "t", "d", %{})
    end
  end

  describe "get/1" do
    test "200: returns the task-domain view of the MR" do
      stub(fn conn ->
        assert conn.method == "GET"

        cond do
          conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "approved" => true,
              "web_url" => "https://gitlab.com/grp/proj/-/merge_requests/42"
            })

          # get/1 also polls the MR's pipelines for CI status.
          conn.request_path == "#{base_path()}/#{@iid}/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok,
              %{
                ref: @ref,
                status: :open,
                approved: true,
                url: "https://gitlab.com/grp/proj/-/merge_requests/42"
              }} = Gitlab.get(@ref)
    end

    test "extracts base_ref (the MR's target branch) for local diffing (bd-5yp6yn)" do
      stub(fn conn ->
        cond do
          conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "target_branch" => "dolphin",
              "sha" => "abc123"
            })

          conn.request_path == "#{base_path()}/#{@iid}/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok, %{base_ref: "dolphin", head_sha: "abc123"}} = Gitlab.get(@ref)
    end

    test "maps merged/closed/locked states and absent approval" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
      end)

      assert {:ok, %{status: :merged, approved: false}} = Gitlab.get(@ref)
    end

    test "404: returns {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Not found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} = Gitlab.get(@ref)
    end

    test "includes pipeline status from the /pipelines endpoint" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 1, "status" => "failed"}])
        end
      end)

      assert {:ok, %{pipeline: :failed}} = Gitlab.get(@ref)
    end

    test "pipeline comes from the head SHA's newest pipeline: an older failed one on the same SHA is superseded" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            Req.Test.json(conn, %{"iid" => @iid, "state" => "opened", "sha" => "head"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            # Deliberately out of order: the pick must not rely on list order.
            Req.Test.json(conn, [
              %{"id" => 5, "sha" => "head", "status" => "failed"},
              %{"id" => 7, "sha" => "head", "status" => "created"},
              %{"id" => 9, "sha" => "older-head", "status" => "success"}
            ])
        end
      end)

      assert {:ok, %{pipeline: :pending}} = Gitlab.get(@ref)
    end

    test "pipeline is :pending (not the previous head's verdict) while the new head has no pipeline yet" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            Req.Test.json(conn, %{"iid" => @iid, "state" => "opened", "sha" => "head"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            Req.Test.json(conn, [%{"id" => 3, "sha" => "prev", "status" => "failed"}])
        end
      end)

      assert {:ok, %{pipeline: :pending}} = Gitlab.get(@ref)
    end

    test "pipeline is :success when the latest pipeline succeeded" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 2, "status" => "success"}])
        end
      end)

      assert {:ok, %{pipeline: :success}} = Gitlab.get(@ref)
    end

    test "pipeline is :running when the latest pipeline is running" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 3, "status" => "running"}])
        end
      end)

      assert {:ok, %{pipeline: :running}} = Gitlab.get(@ref)
    end

    test "pipeline is :pending when the latest pipeline is still queued/preparing" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 4, "status" => "preparing"}])
        end
      end)

      assert {:ok, %{pipeline: :pending}} = Gitlab.get(@ref)
    end

    test "pipeline is :neutral when the latest pipeline is skipped (settled, not CI-still-running, bd-cnytw3)" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 5, "status" => "skipped"}])
        end
      end)

      assert {:ok, %{pipeline: :neutral}} = Gitlab.get(@ref)
    end

    test "pipeline is :neutral when the latest pipeline is manual (settled, not CI-still-running, bd-cnytw3)" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => 6, "status" => "manual"}])
        end
      end)

      assert {:ok, %{pipeline: :neutral}} = Gitlab.get(@ref)
    end

    test "pipeline is nil when no pipelines exist" do
      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([])
        end
      end)

      assert {:ok, %{pipeline: nil}} = Gitlab.get(@ref)
    end
  end

  # #354 Phase 1: get/1 classifies *why* an open MR can't merge so the Watchdog
  # can escalate a blocked merge instead of parking it silently.
  describe "get/1 block_reason (#354)" do
    defp block_get(mr_fields, pipelines \\ []) do
      mr = Map.merge(%{"iid" => @iid, "state" => "opened"}, mr_fields)

      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(mr)

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pipelines)
        end
      end)

      {:ok, result} = Gitlab.get(@ref)
      result
    end

    test "mergeable MR has no block reason" do
      assert block_get(%{"detailed_merge_status" => "mergeable"}).block_reason == nil
    end

    test "has_conflicts classifies as :conflict" do
      assert block_get(%{"has_conflicts" => true}).block_reason == :conflict
    end

    test "detailed_merge_status conflict classifies as :conflict" do
      assert block_get(%{"detailed_merge_status" => "conflict"}).block_reason == :conflict
    end

    test "detailed conflict with has_conflicts=false is rechecked, not trusted (bd-9kfdkf)" do
      test_pid = self()

      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            recheck? = conn.query_string =~ "with_merge_status_recheck=true"
            send(test_pid, {:mr_get, recheck?})

            mr =
              if recheck? do
                %{"detailed_merge_status" => "ci_still_running", "has_conflicts" => false}
              else
                %{"detailed_merge_status" => "conflict", "has_conflicts" => false}
              end

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(Map.merge(%{"iid" => @iid, "state" => "opened"}, mr))

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert {:ok, %{block_reason: nil}} = Gitlab.get(@ref)
      assert_received {:mr_get, false}
      assert_received {:mr_get, true}
    end

    test "need_rebase classifies as :behind_base" do
      assert block_get(%{"detailed_merge_status" => "need_rebase"}).block_reason == :behind_base
    end

    test "ci_must_pass is non-blocking (CI required but not yet failed)" do
      # ci_must_pass means CI hasn't gone green yet — it may still be running.
      # Only a resolved :failed pipeline is a CI block, so this is nil.
      result =
        block_get(%{"detailed_merge_status" => "ci_must_pass"}, [
          %{"id" => 3, "status" => "running"}
        ])

      assert result.block_reason == nil
    end

    test "ci_must_pass with no pipeline on the head classifies as :no_pipeline (#918)" do
      # The project's workflow:rules created no pipeline, so CI can never go green.
      result = block_get(%{"detailed_merge_status" => "ci_must_pass", "head_pipeline" => nil})

      assert result.block_reason == :no_pipeline
    end

    test ":no_pipeline is never ci_clean, even if the legacy merge_status says can_be_merged" do
      result =
        block_get(%{
          "detailed_merge_status" => "ci_must_pass",
          "merge_status" => "can_be_merged",
          "head_pipeline" => nil
        })

      assert result.block_reason == :no_pipeline
      refute result.ci_clean
    end

    test "ci_must_pass whose only pipelines belong to an older head is :no_pipeline too" do
      result =
        block_get(
          %{"detailed_merge_status" => "ci_must_pass", "head_pipeline" => nil, "sha" => "new"},
          [%{"id" => 1, "sha" => "old", "status" => "success"}]
        )

      assert result.block_reason == :no_pipeline
    end

    test "ci_still_running is non-blocking (pipeline in progress, not failed)" do
      assert block_get(%{"detailed_merge_status" => "ci_still_running"}).block_reason == nil
    end

    test "ci_must_pass with a failed pipeline still classifies as :ci_failed" do
      # When CI has actually failed, the resolved pipeline value wins regardless
      # of the detailed-status string.
      result =
        block_get(%{"detailed_merge_status" => "ci_must_pass"}, [
          %{"id" => 9, "status" => "failed"}
        ])

      assert result.block_reason == :ci_failed
    end

    test "transient detailed statuses (preparing/checking/unchecked) are non-blocking" do
      for status <- ["preparing", "checking", "unchecked"] do
        assert block_get(%{"detailed_merge_status" => status}).block_reason == nil,
               "expected #{status} to be non-blocking"
      end
    end

    test "a failed pipeline classifies as :ci_failed" do
      result = block_get(%{}, [%{"id" => 9, "status" => "failed"}])
      assert result.block_reason == :ci_failed
    end

    test "not_approved with no resolvable author classifies as :needs_approval" do
      # No `author.username` on the MR → authorship can't be confirmed as the
      # fleet's, so we never call `/user` and fall back to the generic reason.
      assert block_get(%{"detailed_merge_status" => "not_approved"}).block_reason ==
               :needs_approval
    end

    # A not_approved MR opened by the authenticated fleet identity is parked on a
    # required non-author approval GitLab's rules forbid the author from giving
    # (bd-c3lchp).
    defp block_get_authored(mr_fields, viewer_username) do
      mr = Map.merge(%{"iid" => @iid, "state" => "opened"}, mr_fields)

      stub(fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/merge_requests/42" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(mr)

          "/api/v4/projects/12345/merge_requests/42/pipelines" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          "/api/v4/user" ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"username" => viewer_username})
        end
      end)

      {:ok, result} = Gitlab.get(@ref)
      result
    end

    test "not_approved on a fleet-authored MR classifies as :needs_nonauthor_approval" do
      result =
        block_get_authored(
          %{"detailed_merge_status" => "not_approved", "author" => %{"username" => "fleet-bot"}},
          "fleet-bot"
        )

      assert result.block_reason == :needs_nonauthor_approval
    end

    test "not_approved on an MR authored by someone else stays :needs_approval" do
      result =
        block_get_authored(
          %{"detailed_merge_status" => "not_approved", "author" => %{"username" => "a-human"}},
          "fleet-bot"
        )

      assert result.block_reason == :needs_approval
    end

    test "requested_changes stays :needs_approval even when fleet-authored" do
      # A genuine change request is a review action, not the author-can't-approve
      # park case.
      result =
        block_get_authored(
          %{
            "detailed_merge_status" => "requested_changes",
            "author" => %{"username" => "fleet-bot"}
          },
          "fleet-bot"
        )

      assert result.block_reason == :needs_approval
    end

    test "draft classifies as :draft" do
      assert block_get(%{"draft" => true}).block_reason == :draft
    end

    test "cannot_be_merged without detail and without has_conflicts is non-blocking (bd-1x4r25)" do
      # `merge_status` is GitLab's deprecated, asynchronously-recomputed field —
      # it can read stale "cannot_be_merged" right after the target branch
      # moves, with no real conflict. Without a corroborating `has_conflicts:
      # true`, trust "not settled yet" over "conflict" — and the `conflicting`
      # field the MergeQueue actually dispatches a resolver on must agree.
      result = block_get(%{"merge_status" => "cannot_be_merged"})
      assert result.block_reason == nil
      assert result.conflicting == false
    end

    test "the legacy recheck-in-flight merge statuses are non-blocking (bd-1x4r25)" do
      # `cannot_be_merged_recheck` / `cannot_be_merged_rechecking` are the
      # legacy enum's "a mergeability recheck is queued / running" states, on
      # exactly the older GitLab versions that omit `detailed_merge_status`.
      # They are unsettled by definition — neither a conflict nor a merge rule
      # a human can act on, so they must not page the coordinator.
      for status <- ["cannot_be_merged_recheck", "cannot_be_merged_rechecking"] do
        result = block_get(%{"merge_status" => status})
        assert result.block_reason == nil, "expected #{status} to be non-blocking"
        assert result.conflicting == false
      end
    end

    test "an unrecognized merge_status with no detail still classifies as :blocked_other" do
      # Only the specific legacy statuses known to mean "not settled yet" are
      # forgiven when `detailed_merge_status` is absent (bd-1x4r25 finding 3) —
      # a genuinely unrecognized/future `merge_status` value must still surface
      # as :blocked_other rather than silently becoming non-blocking.
      assert block_get(%{"merge_status" => "some_future_status"}).block_reason == :blocked_other
    end

    test "cannot_be_merged corroborated by has_conflicts still classifies as :conflict" do
      result = block_get(%{"merge_status" => "cannot_be_merged", "has_conflicts" => true})
      assert result.block_reason == :conflict
      assert result.conflicting == true
    end

    test "broken_status alone is non-blocking, not a confirmed conflict (bd-1x4r25)" do
      # GitLab does not document `broken_status` as meaning "conflicts with the
      # target branch" — it is not even listed in the current API docs. Treat
      # it the same as the other not-yet-settled statuses unless corroborated
      # by `has_conflicts: true`. Real GitLab payloads pair `broken_status`
      # with the legacy `merge_status: "cannot_be_merged"`, so the fixture
      # includes it to exercise the coupled shape, not just `detailed_merge_status`
      # in isolation.
      result =
        block_get(%{
          "detailed_merge_status" => "broken_status",
          "merge_status" => "cannot_be_merged"
        })

      assert result.block_reason == nil
      assert result.conflicting == false
    end

    test "broken_status corroborated by has_conflicts still classifies as :conflict" do
      result =
        block_get(%{
          "detailed_merge_status" => "broken_status",
          "merge_status" => "cannot_be_merged",
          "has_conflicts" => true
        })

      assert result.block_reason == :conflict
      assert result.conflicting == true
    end

    test "zero-divergence branch with CI still running is never a :conflict (bd-1x4r25 vs-a7w5g9)" do
      # The exact shape observed in the incident: mergeable branch, merge-base
      # already equal to the target tip, CI still running, no real conflict —
      # yet GitLab's async merge-status recompute can transiently report a
      # broken/cannot_be_merged status (GitLab pairs `broken_status` with the
      # legacy `merge_status: "cannot_be_merged"` in this shape). Neither
      # `block_reason` nor `conflicting` — the field the MergeQueue actually
      # dispatches a resolver on — should treat this as a conflict.
      result =
        block_get(
          %{"detailed_merge_status" => "broken_status", "merge_status" => "cannot_be_merged"},
          [%{"id" => 1, "status" => "running"}]
        )

      assert result.block_reason == nil
      assert result.conflicting == false
    end

    test "logs the raw GitLab merge-status fields alongside a :conflict verdict" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert block_get(%{
                   "detailed_merge_status" => "conflict",
                   "has_conflicts" => true,
                   "target_branch" => "main",
                   "sha" => "deadbeef"
                 }).block_reason == :conflict
        end)

      assert log =~ "conflict"
      assert log =~ "has_conflicts"
      assert log =~ "detailed_merge_status"
      assert log =~ "target_branch"
      assert log =~ "deadbeef"
    end

    test "an unresolved-discussions status classifies as :blocked_other" do
      assert block_get(%{"detailed_merge_status" => "discussions_not_resolved"}).block_reason ==
               :blocked_other
    end

    test "a merged MR carries no block reason" do
      assert block_get(%{"state" => "merged"}).block_reason == nil
    end
  end

  describe "update_branch/1" do
    test "202: PUTs the rebase endpoint and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}/rebase"

        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{"rebase_in_progress" => true})
      end)

      assert :ok = Gitlab.update_branch(@ref)
    end

    test "409: conflict returns {:error, %Error{kind: :conflict}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"message" => "Rebase failed."})
      end)

      assert {:error, %Error{kind: :conflict, status: 409}} = Gitlab.update_branch(@ref)
    end
  end

  # `update_branch/2` — the strategy-aware sync (`merge.sync_strategy`).
  describe "update_branch/2" do
    alias Arbiter.Tasks.Workspace

    defp sync_workspace(merge_extra, repo_paths \\ %{}) do
      %Workspace{
        config: %{
          "merge" => Map.merge(%{"strategy" => "gitlab"}, merge_extra),
          "repo_paths" => repo_paths
        }
      }
    end

    defp git!(cd, args) do
      {out, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
      String.trim(out)
    end

    # A bare origin with `main` and `feature/x`, a clone the workspace maps as
    # repo "app", and a seed clone used to move `main` / `feature/x` upstream.
    defp bare_remote(dir) do
      origin = Path.join(dir, "origin.git")
      seed = Path.join(dir, "seed")
      app = Path.join(dir, "app")
      git!(dir, ["init", "--bare", "--initial-branch=main", origin])
      git!(dir, ["clone", origin, seed])

      for {k, v} <- [{"user.name", "T"}, {"user.email", "t@example.invalid"}] do
        git!(seed, ["config", k, v])
      end

      File.write!(Path.join(seed, "a.txt"), "one\ntwo\nthree\n")
      git!(seed, ["add", "."])
      git!(seed, ["commit", "-m", "base"])
      git!(seed, ["push", "origin", "main"])
      git!(seed, ["checkout", "-b", "feature/x"])
      File.write!(Path.join(seed, "f.txt"), "feature\n")
      git!(seed, ["add", "."])
      git!(seed, ["commit", "-m", "feature"])
      git!(seed, ["push", "origin", "feature/x"])
      git!(seed, ["checkout", "main"])
      git!(dir, ["clone", origin, app])

      for {k, v} <- [{"user.name", "T"}, {"user.email", "t@example.invalid"}] do
        git!(app, ["config", k, v])
      end

      %{origin: origin, seed: seed, app: app}
    end

    defp move_main(seed, file, content) do
      File.write!(Path.join(seed, file), content)
      git!(seed, ["add", "."])
      git!(seed, ["commit", "-m", "main: #{file}"])
      git!(seed, ["push", "origin", "main"])
    end

    defp mr_stub do
      stub(fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "iid" => @iid,
              "state" => "opened",
              "source_branch" => "feature/x",
              "target_branch" => "main"
            })

          "PUT" ->
            send(self(), :rebase_endpoint_called)
            conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"rebase_in_progress" => true})
        end
      end)
    end

    setup %{tmp_dir: dir} do
      previous = Application.get_env(:arbiter, :worktree_root)
      root = Path.join(dir, "worktrees")
      File.mkdir_p!(root)
      Application.put_env(:arbiter, :worktree_root, root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :worktree_root, previous),
          else: Application.delete_env(:arbiter, :worktree_root)
      end)

      %{remote: bare_remote(dir)}
    end

    @tag :tmp_dir
    test "default strategy merges the target into the MR branch and pushes without force",
         %{remote: %{origin: origin, seed: seed, app: app}} do
      mr_stub()
      reviewed = git!(origin, ["rev-parse", "refs/heads/feature/x"])
      move_main(seed, "b.txt", "main change\n")
      workspace = sync_workspace(%{}, %{"app" => app})

      assert :ok = Gitlab.update_branch(@ref, %{workspace: workspace, repo: "app"})

      refute_received :rebase_endpoint_called
      new_head = git!(origin, ["rev-parse", "refs/heads/feature/x"])
      refute new_head == reviewed

      assert {_, 0} =
               System.cmd("git", ["merge-base", "--is-ancestor", reviewed, new_head], cd: origin)

      assert git!(origin, ["rev-parse", new_head <> "^2"]) ==
               git!(origin, ["rev-parse", "refs/heads/main"])
    end

    @tag :tmp_dir
    test "a merge conflict returns a :conflict error and never touches the remote branch",
         %{remote: %{origin: origin, seed: seed, app: app}} do
      mr_stub()
      git!(seed, ["checkout", "feature/x"])
      File.write!(Path.join(seed, "a.txt"), "one\nFEATURE\nthree\n")
      git!(seed, ["commit", "-am", "feature edits a.txt"])
      git!(seed, ["push", "origin", "feature/x"])
      git!(seed, ["checkout", "main"])
      move_main(seed, "a.txt", "one\nMAIN\nthree\n")
      head = git!(origin, ["rev-parse", "refs/heads/feature/x"])
      workspace = sync_workspace(%{}, %{"app" => app})

      assert {:error, %Error{kind: :conflict, raw: {:conflict, ["a.txt"]}}} =
               Gitlab.update_branch(@ref, %{workspace: workspace, repo: "app"})

      refute_received :rebase_endpoint_called
      assert git!(origin, ["rev-parse", "refs/heads/feature/x"]) == head
    end

    @tag :tmp_dir
    test "sync_strategy: rebase keeps the rebase endpoint", %{remote: %{origin: origin, app: app}} do
      mr_stub()
      head = git!(origin, ["rev-parse", "refs/heads/feature/x"])
      workspace = sync_workspace(%{"sync_strategy" => "rebase"}, %{"app" => app})

      assert :ok = Gitlab.update_branch(@ref, %{workspace: workspace, repo: "app"})

      assert_received :rebase_endpoint_called
      assert git!(origin, ["rev-parse", "refs/heads/feature/x"]) == head
    end

    @tag :tmp_dir
    test "a per-repo sync_strategy override wins", %{remote: %{app: app}} do
      mr_stub()

      workspace =
        sync_workspace(
          %{"sync_strategy" => "merge", "repos" => %{"app" => %{"sync_strategy" => "rebase"}}},
          %{"app" => app}
        )

      assert :ok = Gitlab.update_branch(@ref, %{workspace: workspace, repo: "app"})
      assert_received :rebase_endpoint_called
    end

    @tag :tmp_dir
    test "a repo with no local checkout is an error, not a rebase", %{remote: _} do
      mr_stub()
      workspace = sync_workspace(%{})

      assert {:error, %Error{kind: :git_push_failed, raw: :no_repo_path}} =
               Gitlab.update_branch(@ref, %{workspace: workspace, repo: "app"})

      refute_received :rebase_endpoint_called
    end

    @tag :tmp_dir
    test "with no workspace context it keeps the rebase endpoint (update_branch/1)", %{remote: _} do
      mr_stub()
      assert :ok = Gitlab.update_branch(@ref)
      assert_received :rebase_endpoint_called
    end
  end

  describe "merge/2 405 classification (#918)" do
    defp merge_405_stub(mr_fields) do
      stub(fn conn ->
        case conn.method do
          "PUT" ->
            conn
            |> Plug.Conn.put_status(405)
            |> Req.Test.json(%{"message" => "405 Method Not Allowed"})

          "GET" ->
            Req.Test.json(conn, Map.merge(%{"iid" => @iid, "state" => "opened"}, mr_fields))
        end
      end)
    end

    test "a 405 is :not_mergeable, not :conflict, when the MR has no conflicts" do
      merge_405_stub(%{"has_conflicts" => false, "detailed_merge_status" => "ci_must_pass"})

      assert {:error, %Error{kind: :not_mergeable, status: 405, message: message}} =
               Gitlab.merge(@ref, "abc")

      assert message =~ "405 Method Not Allowed"
      assert message =~ "ci_must_pass"
    end

    test "a 405 stays :conflict when the MR reports has_conflicts" do
      merge_405_stub(%{"has_conflicts" => true})
      assert {:error, %Error{kind: :conflict, status: 405}} = Gitlab.merge(@ref, "abc")
    end
  end

  describe "merge/2" do
    test "200: fetches MR, extracts head SHA, sends it in merge request body" do
      stub(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "sha" => "abc123def456"
            })

          conn.method == "PUT" and conn.request_path == "#{base_path()}/#{@iid}/merge" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["sha"] == "abc123def456"

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
        end
      end)

      assert :ok = Gitlab.merge(@ref, nil)
    end

    test "an expected_sha is sent verbatim, with no head re-read (bd-dxgris)" do
      # The reviewed SHA IS the precondition — re-reading the head would defeat
      # the guard by replacing it with whatever landed since.
      test_pid = self()

      stub(fn conn ->
        if conn.method == "GET", do: send(test_pid, :unexpected_head_read)

        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}/merge"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["sha"] == "reviewed-sha"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
      end)

      assert :ok = Gitlab.merge(@ref, "reviewed-sha")
      refute_received :unexpected_head_read
    end

    test "409 when the branch advanced past the expected_sha" do
      stub(fn conn ->
        assert conn.method == "PUT"

        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"message" => "SHA does not match HEAD of source branch"})
      end)

      assert {:error, %Error{status: 409}} = Gitlab.merge(@ref, "reviewed-sha")
    end

    test "422 with SHA validation error when merge fails due to stale head" do
      stub(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "sha" => "abc123def456"
            })

          conn.method == "PUT" and conn.request_path == "#{base_path()}/#{@iid}/merge" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "SHA must be provided when merging (validation_failed)"
            })
        end
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} = Gitlab.merge(@ref, nil)
    end

    test "405 with no reported conflict returns :not_mergeable, not :conflict (#918)" do
      stub(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "sha" => "abc123def456"
            })

          conn.method == "PUT" ->
            conn
            |> Plug.Conn.put_status(405)
            |> Req.Test.json(%{"message" => "405 Method Not Allowed"})
        end
      end)

      assert {:error, %Error{kind: :not_mergeable, status: 405}} = Gitlab.merge(@ref, nil)
    end

    test "sends squash parameter when merge_method=squash is configured" do
      stub(fn conn ->
        cond do
          conn.method == "GET" and conn.request_path == "#{base_path()}/#{@iid}" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "iid" => @iid,
              "state" => "opened",
              "sha" => "abc123def456"
            })

          conn.method == "PUT" and conn.request_path == "#{base_path()}/#{@iid}/merge" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["sha"] == "abc123def456"
            # GitLab's merge API only accepts "squash" (boolean), not "merge_method"
            assert decoded["squash"] == true

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"iid" => @iid, "state" => "merged"})
        end
      end)

      # Set merge_method in config
      Config.put_active(%{
        "host" => @host,
        "project_id" => @project,
        "credentials_ref" => "env:#{@env_var}",
        "default_target_branch" => "main",
        "merge_method" => "squash"
      })

      assert :ok = Gitlab.merge(@ref, nil)
    end

    test "GET 500: returns {:error, %Error{status: 500}} without attempting the merge PUT" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "#{base_path()}/#{@iid}"

        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "Internal Server Error"})
      end)

      assert {:error, %Error{status: 500}} = Gitlab.merge(@ref, nil)
    end

    test "GET transport failure: returns a transport_error, not a crash" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{}} = Gitlab.merge(@ref, nil)
    end

    test "GET 200 with no sha in the body: returns a validation error naming the cause" do
      stub(fn conn ->
        assert conn.method == "GET"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "opened"})
      end)

      assert {:error, %Error{kind: :validation_failed}} = Gitlab.merge(@ref, nil)
    end
  end

  # bd-6bg54c / #1573 (AC2). The merge guard needs to ask "does this head have
  # the same net diff against the base as the reviewed commit did?" — which is a
  # `base...head` compare, not the MR's own changes. GitHub's adapter already
  # honoured `%{base:, head:}`; GitLab's silently ignored its opts and always
  # answered with the whole-MR diff, which would have made every comparison
  # trivially equal and the guard useless.
  describe "ancestor?/3" do
    # P4 (bd-df3zlo / #1736) AC1. `Coverage.decide/3`'s rule 2 needs an
    # ancestry *proof* before it will call a head "the forge lagging our own
    # push", and until this existed no adapter could supply one.
    @ancestor String.duplicate("a", 40)
    @descendant String.duplicate("b", 40)

    test "true when the merge base of the two commits IS the ancestor" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v4/projects/#{@project}/repository/merge_base"
        assert conn.query_string =~ "refs%5B%5D=#{@ancestor}"
        assert conn.query_string =~ "refs%5B%5D=#{@descendant}"

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => @ancestor})
      end)

      assert Gitlab.ancestor?(@ref, @ancestor, @descendant) == {:ok, true}
    end

    test "false when the merge base is some earlier commit (the two diverged)" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"id" => String.duplicate("c", 40)})
      end)

      assert Gitlab.ancestor?(@ref, @ancestor, @descendant) == {:ok, false}
    end

    test "an HTTP failure is an error, never a `false`" do
      # Both shapes GitLab actually returns, verified against gitlab.com:
      # 400 `Could not find ref` for a sha the server has not seen — which is
      # the forge-lag case itself, where the answer must be "could not tell"
      # rather than "unrelated" — and 404 when the two commits have no merge
      # base at all.
      for {status, message, kind} <- [
            {400, "Could not find ref: #{@descendant}", :validation_failed},
            {404, "404 Merge Base Not Found", :not_found}
          ] do
        stub(fn conn ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"message" => message})
        end)

        assert {:error, %Error{kind: ^kind}} = Gitlab.ancestor?(@ref, @ancestor, @descendant)
      end
    end

    test "a body with no commit id is an error, never a `false`" do
      stub(fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"nope" => true}) end)

      assert {:error, {:unexpected_merge_base, _}} =
               Gitlab.ancestor?(@ref, @ancestor, @descendant)
    end

    test "identical commits are ancestors of themselves, with no request at all" do
      stub(fn _conn -> flunk("ancestor?/3 must not call the forge for an identical pair") end)

      assert Gitlab.ancestor?(@ref, @ancestor, @ancestor) == {:ok, true}
    end

    test "a malformed sha is rejected without a request" do
      stub(fn _conn -> flunk("ancestor?/3 must not call the forge with a non-sha") end)

      assert {:error, {:invalid_sha, "main"}} =
               Gitlab.ancestor?(@ref, "main", @descendant)
    end
  end

  describe "get_diff/2" do
    test "with no range, returns the MR's own changes" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "#{base_path()}/#{@iid}/changes"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "changes" => [
            %{"old_path" => "a.ex", "new_path" => "a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b\n"}
          ]
        })
      end)

      assert {:ok, diff} = Gitlab.get_diff(@ref, %{})
      assert diff =~ "--- a/a.ex"
      assert diff =~ "+b"
    end

    test "an overflowed /changes is an error when the caller asks for a complete diff" do
      body = %{
        "overflow" => true,
        "changes" => [
          %{"old_path" => "a.ex", "new_path" => "a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b\n"}
        ]
      }

      stub(fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(body) end)

      assert {:error, :diff_overflow} = Gitlab.get_diff(@ref, %{complete: true})
      # Every other caller keeps the partial diff it always got.
      assert {:ok, diff} = Gitlab.get_diff(@ref, %{})
      assert diff =~ "+b"
    end

    test "a non-overflowed /changes is returned whole for a complete-diff caller" do
      body = %{
        "overflow" => false,
        "changes" => [
          %{"old_path" => "a.ex", "new_path" => "a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b\n"}
        ]
      }

      stub(fn conn -> conn |> Plug.Conn.put_status(200) |> Req.Test.json(body) end)

      assert {:ok, diff} = Gitlab.get_diff(@ref, %{complete: true})
      assert diff =~ "+b"
    end

    test "with a {base, head} range, compares the two refs instead" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/v4/projects/#{@project}/repository/compare"
        assert conn.query_string =~ "from=main"
        assert conn.query_string =~ "to=head-sha"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "diffs" => [
            %{"old_path" => "a.ex", "new_path" => "a.ex", "diff" => "@@ -1 +1 @@\n-a\n+b\n"}
          ]
        })
      end)

      assert {:ok, diff} = Gitlab.get_diff(@ref, %{base: "main", head: "head-sha"})
      assert diff =~ "--- a/a.ex"
      assert diff =~ "+b"
    end

    test "string keys are honoured too, and a blank endpoint falls back to the MR diff" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"changes" => [], "diffs" => []})
      end)

      assert {:ok, _} = Gitlab.get_diff(@ref, %{"base" => "main", "head" => "x"})
      assert_received {:path, compare_path}
      assert compare_path == "/api/v4/projects/#{@project}/repository/compare"

      assert {:ok, _} = Gitlab.get_diff(@ref, %{base: "main", head: ""})
      assert_received {:path, mr_path}
      assert mr_path == "#{base_path()}/#{@iid}/changes"
    end

    test "a compare error surfaces as {:error, %Error{}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "404 Ref Not Found"})
      end)

      assert {:error, %Error{status: 404}} = Gitlab.get_diff(@ref, %{base: "main", head: "nope"})
    end
  end

  describe "close/1" do
    test "PUTs state_event=close and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"state_event" => "close"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid, "state" => "closed"})
      end)

      assert :ok = Gitlab.close(@ref)
    end
  end

  describe "add_comment/2" do
    test "POSTs a note and returns :ok" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "#{base_path()}/#{@iid}/notes"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "looks good"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 99})
      end)

      assert :ok = Gitlab.add_comment(@ref, "looks good")
    end
  end

  describe "request_review/2" do
    test "PUTs reviewer_ids and returns :ok" do
      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "#{base_path()}/#{@iid}"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"reviewer_ids" => [3, 4]}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"iid" => @iid})
      end)

      assert :ok = Gitlab.request_review(@ref, [3, 4])
    end
  end

  describe "link_for/1" do
    test "returns \"\" and warns rather than emit a numeric-id URL when the path lookup fails" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Gitlab.link_for(@ref) == ""
        end)

      assert log =~ "path_with_namespace"
      assert log =~ "12345"
    end

    test "does not cache a failed lookup" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      ExUnit.CaptureLog.capture_log(fn -> assert Gitlab.link_for(@ref) == "" end)

      stub(fn conn -> Req.Test.json(conn, %{"path_with_namespace" => "g/p"}) end)
      assert Gitlab.link_for(@ref) == "https://gitlab.com/g/p/-/merge_requests/42"
    end

    test "the resolved path is cached across processes (one fetch)" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :fetched)
        Req.Test.json(conn, %{"path_with_namespace" => "g/p"})
      end)

      expected = "https://gitlab.com/g/p/-/merge_requests/42"
      assert Gitlab.link_for(@ref) == expected
      assert_received :fetched

      # A fresh process has no Req stub ownership and no pdict cache: only a
      # durable cache can answer.
      url =
        Task.async(fn ->
          Config.put_active(%{
            "host" => @host,
            "project_id" => @project,
            "credentials_ref" => "env:#{@env_var}"
          })

          Gitlab.link_for(@ref)
        end)
        |> Task.await()

      assert url == expected
      refute_received :fetched
    end

    test "uses the repo's own project_id (merge.repos.<repo>) for the link" do
      stub(fn conn ->
        path =
          case conn.request_path do
            "/api/v4/projects/55399962" -> "emricare/tonic"
            "/api/v4/projects/81204390" -> "emricare/tonic_device"
          end

        Req.Test.json(conn, %{"path_with_namespace" => path})
      end)

      ws = %Arbiter.Tasks.Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => @host,
              "project_id" => 55_399_962,
              "credentials_ref" => "env:#{@env_var}"
            },
            "repos" => %{"tonic_device" => %{"config" => %{"project_id" => 81_204_390}}}
          }
        }
      }

      assert Arbiter.Mergers.link_for_workspace(ws, @ref, "tonic_device") ==
               "https://gitlab.com/emricare/tonic_device/-/merge_requests/42"

      assert Arbiter.Mergers.link_for_workspace(ws, @ref, "tonic") ==
               "https://gitlab.com/emricare/tonic/-/merge_requests/42"
    end

    test "resolves numeric project_id to namespace/project path for correct URL" do
      # Numeric project_id requires API lookup to get the correct path
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v4/projects/68258632"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "id" => 68_258_632,
              "path_with_namespace" => "ryanborn/vstim",
              "web_url" => "https://gitlab.com/ryanborn/vstim"
            })

          _ ->
            Plug.Conn.send_resp(conn, 404, "Not found")
        end
      end)

      Config.put_active(%{
        "host" => @host,
        "project_id" => 68_258_632,
        "credentials_ref" => "env:#{@env_var}"
      })

      assert Gitlab.link_for(@ref) == "https://gitlab.com/ryanborn/vstim/-/merge_requests/42"
    end

    test "uses string-form project_id directly without API lookup" do
      Config.put_active(%{
        "host" => @host,
        "project_id" => "mygroup/myproject",
        "credentials_ref" => "env:#{@env_var}"
      })

      # No stub needed - this test verifies string-form project_id works without API calls
      assert Gitlab.link_for(@ref) == "https://gitlab.com/mygroup/myproject/-/merge_requests/42"
    end

    test "returns \"\" when config is missing" do
      Config.clear()
      assert Gitlab.link_for(@ref) == ""
    end
  end

  describe "submit_review/4" do
    @approve_path "/api/v4/projects/12345/merge_requests/42/approve"
    @notes_path "/api/v4/projects/12345/merge_requests/42/notes"
    @unapprove_path "/api/v4/projects/12345/merge_requests/42/unapprove"

    test ":approve posts to /approve then posts an Approved summary note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"approved" => true})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "Approved"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved: no findings.", %{})
    end

    test ":request_changes unapproves and posts a Requesting changes note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @unapprove_path} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "Requesting changes"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 2})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :request_changes, "Fix these.", %{})
    end

    test "422 self-approve on :approve falls back to a VERDICT note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{
              "message" => "You are not allowed to approve this merge request."
            })

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "VERDICT: APPROVE"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 3})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end

    test "401 with author-approval message on :approve falls back to a VERDICT note" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"message" => "Author cannot approve own merge request."})

          {"POST", @notes_path} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body)["body"] =~ "VERDICT: APPROVE"
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 4})
        end
      end)

      assert {:ok, _} = Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end

    test "422 with an unrelated message on :approve is not swallowed" do
      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", @approve_path} ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"message" => "Approvals are not configured for this project."})
        end
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422}} =
               Gitlab.submit_review(@ref, :approve, "Approved.", %{})
    end
  end

  describe "parse_ref/1" do
    test "accepts the !iid shorthand" do
      assert {:ok, "!42"} = Gitlab.parse_ref("!42")
    end

    test "accepts a bare integer (binary and integer)" do
      assert {:ok, "!42"} = Gitlab.parse_ref("42")
      assert {:ok, "!42"} = Gitlab.parse_ref(42)
    end

    test "accepts a full GitLab MR URL" do
      assert {:ok, "!42"} =
               Gitlab.parse_ref("https://gitlab.com/grp/proj/-/merge_requests/42")
    end

    test "rejects nonsense" do
      assert :error = Gitlab.parse_ref("not-a-ref")
      assert :error = Gitlab.parse_ref("!")
      assert :error = Gitlab.parse_ref(%{})
    end

    # bd-3jjk0e: tolerate a leading `gitlab:` strategy prefix so a prefixed ref
    # still resolves to the underlying iid.
    test "tolerates a leading gitlab: strategy prefix" do
      assert {:ok, "!42"} = Gitlab.parse_ref("gitlab:!42")
      assert {:ok, "!42"} = Gitlab.parse_ref("gitlab:42")
    end
  end

  describe "config_missing" do
    test "every callback returns {:error, %Error{kind: :config_missing}} with no active config" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Gitlab.open("b", "t", "d", %{})
      assert {:error, %Error{kind: :config_missing}} = Gitlab.get(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.update_branch(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.failing_check_logs(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.merge(@ref, nil)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.close(@ref)
      assert {:error, %Error{kind: :config_missing}} = Gitlab.add_comment(@ref, "x")
      assert {:error, %Error{kind: :config_missing}} = Gitlab.request_review(@ref, [1])
    end

    test "missing credentials env var surfaces as config_missing" do
      System.delete_env(@env_var)

      assert {:error, %Error{kind: :config_missing, message: msg}} =
               Gitlab.open("b", "t", "d", %{})

      assert msg =~ @env_var
    end
  end

  # override_repo/2 — per-repo GitLab project overrides for multi-project
  # workspaces (bd-c9vb0r).
  describe "override_repo/2" do
    defp workspace_with_repos(repos) do
      %Arbiter.Tasks.Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => @host,
              "project_id" => @project,
              "credentials_ref" => "env:#{@env_var}",
              "repos" => repos
            }
          }
        }
      }
    end

    test "merges a matching repo override's project_id over the active config" do
      ws = workspace_with_repos(%{"tonic_device" => %{"project_id" => 999}})

      assert :ok = Config.override_repo(ws, "tonic_device")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == "999"
      assert cfg.host == @host
    end

    test "leaves the active config unchanged when the repo has no override" do
      ws = workspace_with_repos(%{"tonic_device" => %{"project_id" => 999}})

      assert :ok = Config.override_repo(ws, "tonic")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == to_string(@project)
    end

    test "leaves the active config unchanged when the workspace has no repos map" do
      ws = %Arbiter.Tasks.Workspace{
        config: %{"merge" => %{"strategy" => "gitlab", "config" => %{}}}
      }

      assert :ok = Config.override_repo(ws, "tonic_device")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == to_string(@project)
    end

    test "is a no-op for a nil repo" do
      ws = workspace_with_repos(%{"tonic_device" => %{"project_id" => 999}})

      assert :ok = Config.override_repo(ws, nil)
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == to_string(@project)
    end

    test "is a no-op for a blank repo" do
      ws = workspace_with_repos(%{"tonic_device" => %{"project_id" => 999}})

      assert :ok = Config.override_repo(ws, "")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == to_string(@project)
    end

    test "an overridden credentials_ref resolves its own token" do
      other_env = "GTE_GITLAB_TEST_TOKEN_OTHER"
      System.put_env(other_env, "other-repo-token")
      on_exit(fn -> System.delete_env(other_env) end)

      ws =
        workspace_with_repos(%{
          "tonic_device" => %{"project_id" => 999, "credentials_ref" => "env:#{other_env}"}
        })

      assert :ok = Config.override_repo(ws, "tonic_device")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == "999"
      assert cfg.token == "other-repo-token"
    end

    test "matches a forge-qualified slug against a bare repos key (bd-bnakt8)" do
      ws = workspace_with_repos(%{"tonic_device" => %{"project_id" => 999}})

      assert :ok = Config.override_repo(ws, "emricare/tonic_device")
      assert {:ok, cfg} = Config.resolve()
      assert cfg.project_id == "999"
    end
  end

  # ref_for_pr/2 — construct an mr_ref for an external MR (bd-d4ealy).
  describe "ref_for_pr/2" do
    test "parses an MR URL into a !iid ref" do
      assert {:ok, "!7"} =
               Gitlab.ref_for_pr("https://gitlab.com/group/proj/-/merge_requests/7", %{})
    end

    test "parses a bare iid" do
      assert {:ok, "!42"} = Gitlab.ref_for_pr("42", %{})
    end

    test "parses GitLab's own !N shorthand" do
      assert {:ok, "!42"} = Gitlab.ref_for_pr("!42", %{})
    end

    test "an unparseable identifier returns a validation error" do
      assert {:error, %Error{kind: :validation_failed}} = Gitlab.ref_for_pr("nonsense", %{})
    end
  end

  describe "failing_check_logs/1" do
    @pipelines_path "/api/v4/projects/12345/merge_requests/42/pipelines"
    @pipeline_id 99
    @jobs_path "/api/v4/projects/12345/pipelines/99/jobs"
    @job_id 55
    @trace_path "/api/v4/projects/12345/jobs/55/trace"

    test "returns failing job names, log tails, and URLs" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @pipeline_id, "status" => "failed"}])

          @jobs_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{
                "id" => @job_id,
                "name" => "rspec",
                "status" => "failed",
                "web_url" => "https://gitlab.com/grp/proj/-/jobs/55"
              }
            ])

          @trace_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Plug.Conn.resp(200, "some test output\nfailure at line 42")
        end
      end)

      assert {:ok, [check]} = Gitlab.failing_check_logs(@ref)
      assert check.name == "rspec"
      assert check.summary =~ "failure at line 42"
      assert check.url == "https://gitlab.com/grp/proj/-/jobs/55"
    end

    test "carries the job's status and failure_reason for the CI triage (#1144)" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @pipeline_id, "status" => "failed"}])

          @jobs_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{
                "id" => @job_id,
                "name" => "rspec",
                "status" => "failed",
                "failure_reason" => "runner_system_failure",
                "web_url" => "https://gitlab.com/grp/proj/-/jobs/55"
              }
            ])

          @trace_path ->
            conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, "")
        end
      end)

      assert {:ok, [check]} = Gitlab.failing_check_logs(@ref)
      assert check.failure_reason == "runner_system_failure"
      assert check.status == "failed"
    end

    defp trace_stub(pipelines, jobs, trace) do
      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(pipelines)

          "/api/v4/projects/12345/pipelines/" <> _ ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(jobs)

          @trace_path ->
            conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, trace)
        end
      end)
    end

    test "flags an excerpt that dropped failure blocks as truncated (bd-3ij7dw)" do
      block = fn n ->
        ["  #{n}) test t#{n} (BigTest)", "     test/big_#{n}_test.exs:#{n}", "     boom"] ++
          for(i <- 1..25, do: "     detail #{i} of #{n}") ++ [""]
      end

      big = Enum.join(Enum.flat_map(1..40, block), "\n")
      jobs = [%{"id" => @job_id, "name" => "rspec", "status" => "failed"}]
      pipelines = [%{"id" => @pipeline_id, "status" => "failed", "sha" => "h1"}]

      trace_stub(pipelines, jobs, big)
      assert {:ok, [%{truncated: true}]} = Gitlab.failing_check_logs(@ref)

      trace_stub(pipelines, jobs, "  1) test a (ATest)\n     test/a_test.exs:3\n     boom\n")
      assert {:ok, [%{truncated: false}]} = Gitlab.failing_check_logs(@ref)
    end

    test "only the pipeline on the MR's head sha is read; an older head's red is not (bd-3ij7dw)" do
      jobs = [%{"id" => @job_id, "name" => "rspec", "status" => "failed"}]

      # Newest pipeline (current head h2) is running; the failed one is for the old head h1.
      pipelines = [
        %{"id" => 100, "status" => "running", "sha" => "h2"},
        %{"id" => @pipeline_id, "status" => "failed", "sha" => "h1"}
      ]

      trace_stub(pipelines, jobs, "boom")
      assert {:ok, []} = Gitlab.failing_check_logs(@ref)
    end

    test "a failed pipeline on the head is found past newer pipelines of the same head" do
      jobs = [%{"id" => @job_id, "name" => "rspec", "status" => "failed"}]

      pipelines = [
        %{"id" => 101, "status" => "success", "sha" => "h2"},
        %{"id" => @pipeline_id, "status" => "failed", "sha" => "h2"}
      ]

      trace_stub(pipelines, jobs, "boom")
      assert {:ok, [%{name: "rspec"}]} = Gitlab.failing_check_logs(@ref)
    end

    test "jobs allowed to fail are not failing checks (bd-3ij7dw)" do
      jobs = [
        %{"id" => @job_id, "name" => "rspec", "status" => "failed", "allow_failure" => false},
        %{"id" => 56, "name" => "lint-soft", "status" => "failed", "allow_failure" => true}
      ]

      trace_stub([%{"id" => @pipeline_id, "status" => "failed", "sha" => "h1"}], jobs, "boom")
      assert {:ok, [%{name: "rspec"}]} = Gitlab.failing_check_logs(@ref)
    end

    test "returns {:ok, []} when no pipelines exist" do
      stub(fn conn ->
        assert conn.request_path == @pipelines_path
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      assert {:ok, []} = Gitlab.failing_check_logs(@ref)
    end

    test "returns {:ok, []} when the latest pipeline succeeded" do
      stub(fn conn ->
        assert conn.request_path == @pipelines_path

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json([%{"id" => @pipeline_id, "status" => "success"}])
      end)

      assert {:ok, []} = Gitlab.failing_check_logs(@ref)
    end

    test "skips successful jobs in a failed pipeline" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @pipeline_id, "status" => "failed"}])

          @jobs_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"id" => 10, "name" => "build", "status" => "success"},
              %{
                "id" => @job_id,
                "name" => "test",
                "status" => "failed",
                "web_url" => "https://gitlab.com/grp/proj/-/jobs/55"
              }
            ])

          "/api/v4/projects/12345/jobs/10/trace" ->
            conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, "build ok")

          @trace_path ->
            conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, "test failed")
        end
      end)

      assert {:ok, [check]} = Gitlab.failing_check_logs(@ref)
      assert check.name == "test"
    end

    test "log tail is truncated to 4_000 chars (keeps the tail, not the head)" do
      long_log = String.duplicate("x", 5_000)

      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @pipeline_id, "status" => "failed"}])

          @jobs_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([
              %{"id" => @job_id, "name" => "rspec", "status" => "failed"}
            ])

          @trace_path ->
            conn |> Plug.Conn.put_status(200) |> Plug.Conn.resp(200, long_log)
        end
      end)

      assert {:ok, [check]} = Gitlab.failing_check_logs(@ref)
      assert String.starts_with?(check.summary, "…")
      assert String.length(check.summary) == 4_001
    end

    test "trace fetch failure yields an empty summary, not an error" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @pipeline_id, "status" => "failed"}])

          @jobs_path ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"id" => @job_id, "name" => "rspec", "status" => "failed"}])

          @trace_path ->
            conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "forbidden"})
        end
      end)

      assert {:ok, [check]} = Gitlab.failing_check_logs(@ref)
      assert check.name == "rspec"
      assert check.summary == ""
    end
  end

  describe "list_open/0" do
    test "GETs opened MRs and returns normalized open_mr list" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == base_path()
        assert conn.query_string =~ "state=opened"
        assert conn.query_string =~ "per_page=100"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json([
          %{
            "iid" => 42,
            "title" => "Implement feature X",
            "web_url" => "https://gitlab.com/group/project/-/merge_requests/42"
          }
        ])
      end)

      assert {:ok, [mr]} = Gitlab.list_open()
      assert mr.ref == "!42"
      assert mr.number == 42
      assert mr.title == "Implement feature X"
      assert mr.url == "https://gitlab.com/group/project/-/merge_requests/42"
    end

    test "no open MRs → {:ok, []}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      assert {:ok, []} = Gitlab.list_open()
    end

    test "missing config → {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Gitlab.list_open()
    end
  end

  describe "list_open_review_threads/1" do
    test "GETs discussions and returns only unresolved resolvable threads, normalized" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "#{base_path()}/#{@iid}/discussions"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json([
          # Unresolved resolvable diff thread → kept.
          %{
            "id" => "disc_open",
            "notes" => [
              %{
                "resolvable" => true,
                "resolved" => false,
                "body" => "please fix",
                "author" => %{"username" => "reviewer"},
                "position" => %{"new_path" => "lib/foo.ex", "new_line" => 9}
              }
            ]
          },
          # Resolved thread → dropped.
          %{
            "id" => "disc_resolved",
            "notes" => [%{"resolvable" => true, "resolved" => true, "body" => "ok"}]
          },
          # Non-resolvable general note → dropped.
          %{
            "id" => "disc_general",
            "notes" => [%{"resolvable" => false, "body" => "just a comment"}]
          }
        ])
      end)

      assert {:ok, [thread]} = Gitlab.list_open_review_threads(@ref)
      assert thread.id == "disc_open"
      assert thread.path == "lib/foo.ex"
      assert thread.line == 9
      assert thread.author == "reviewer"
      assert thread.body == "please fix"
      assert [%{author: "reviewer", body: "please fix"}] = thread.comments
    end

    test "returns the full note list as :comments, last entry last (bd-45x4yo)" do
      # answered_by_us?/2 (pr_patrol.ex) reads `List.last(comments)[:author]`
      # to detect a thread we've already replied to. GitLab discussions come
      # back with every note already, so :comments must carry all of them in
      # order — not just the opener — or GitLab stays exposed to the same
      # unbounded PRPatrol re-dispatch loop this task fixed on GitHub.
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json([
          %{
            "id" => "disc_multi",
            "notes" => [
              %{
                "id" => 1,
                "resolvable" => true,
                "resolved" => false,
                "body" => "wrong finding",
                "author" => %{"username" => "reviewer"},
                "position" => %{"new_path" => "lib/foo.ex", "new_line" => 9}
              },
              %{
                "id" => 2,
                "resolvable" => true,
                "resolved" => false,
                "body" => "actually this is correct, see lib/foo.ex:9",
                "author" => %{"username" => "arbiter-bot"}
              }
            ]
          }
        ])
      end)

      assert {:ok, [thread]} = Gitlab.list_open_review_threads(@ref)
      assert Enum.map(thread.comments, & &1.id) == [1, 2]
      assert List.last(thread.comments).author == "arbiter-bot"
    end

    test "no discussions → {:ok, []}" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end)

      assert {:ok, []} = Gitlab.list_open_review_threads(@ref)
    end
  end

  describe "self_approved?/1" do
    defp approvals_get(approved_by, viewer_username) do
      stub(fn conn ->
        cond do
          conn.request_path == "#{base_path()}/#{@iid}/approvals" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"approved_by" => approved_by})

          conn.request_path == "/api/v4/user" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"username" => viewer_username})
        end
      end)

      Gitlab.self_approved?(@ref)
    end

    test "own username present in approved_by → {:ok, true}" do
      approved_by = [%{"user" => %{"username" => "fleet-bot"}}]

      assert {:ok, true} = approvals_get(approved_by, "fleet-bot")
    end

    test "only a different user approved → {:ok, false}" do
      approved_by = [%{"user" => %{"username" => "a-human"}}]

      assert {:ok, false} = approvals_get(approved_by, "fleet-bot")
    end

    test "own identity unresolvable → {:ok, false} (fails open)" do
      stub(fn conn ->
        cond do
          conn.request_path == "#{base_path()}/#{@iid}/approvals" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"approved_by" => [%{"user" => %{"username" => "fleet-bot"}}]})

          conn.request_path == "/api/v4/user" ->
            conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "unauthorized"})
        end
      end)

      assert {:ok, false} = Gitlab.self_approved?(@ref)
    end

    test "approvals fetch hard-fails → {:error, _}" do
      stub(fn conn ->
        assert conn.request_path == "#{base_path()}/#{@iid}/approvals"
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:error, %Error{}} = Gitlab.self_approved?(@ref)
    end

    test "no active config → {:error, %Error{kind: :config_missing}}" do
      Config.clear()

      assert {:error, %Error{kind: :config_missing}} = Gitlab.self_approved?(@ref)
    end
  end

  describe "rerun_ci/2" do
    @mr_path "/api/v4/projects/12345/merge_requests/42"
    @mr_pipelines_path "/api/v4/projects/12345/merge_requests/42/pipelines"
    @rerun_jobs_path "/api/v4/projects/12345/pipelines/99/jobs"
    @retry_path "/api/v4/projects/12345/pipelines/99/retry"
    @new_pipeline_path "/api/v4/projects/12345/pipeline"
    @mr_pipeline_path "/api/v4/projects/12345/merge_requests/42/pipelines"

    # Routes the MR / pipelines / jobs reads; `extra` handles the POST under test
    # and the stub reports what it received.
    defp rerun_stub(pipelines, jobs, extra) do
      test = self()

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", @mr_path} ->
            Req.Test.json(conn, %{"sha" => "abc", "source_branch" => "feat/x"})

          {"GET", @mr_pipelines_path} ->
            Req.Test.json(conn, pipelines)

          {"GET", @rerun_jobs_path} ->
            Req.Test.json(conn, jobs)

          {"POST", path} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:post, path, raw})
            extra.(conn)
        end
      end)
    end

    defp failed_pipeline(id \\ 99),
      do: %{"id" => id, "sha" => "abc", "status" => "failed", "web_url" => "https://gl/p/#{id}"}

    defp created(conn, id) do
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"id" => id, "web_url" => "https://gl/p/#{id}"})
    end

    test ":failed_jobs hits the pipeline retry endpoint" do
      rerun_stub([failed_pipeline()], [], &created(&1, 99))

      assert {:ok, result} = Gitlab.rerun_ci(@ref, %{mode: :failed_jobs})
      assert_received {:post, @retry_path, _}
      assert result.mode == :failed_jobs
      assert result.run_id == 99
      assert result.url == "https://gl/p/99"
      assert is_list(result.reused_jobs)
      assert is_binary(result.rationale)
      assert result.run_attempt == 1
    end

    test ":all_jobs creates a merge request pipeline, not a branch pipeline" do
      rerun_stub([failed_pipeline()], [], &created(&1, 100))

      assert {:ok, result} = Gitlab.rerun_ci(@ref, %{mode: :all_jobs})
      assert_received {:post, @mr_pipeline_path, _}
      refute_received {:post, @new_pipeline_path, _}
      assert result.mode == :all_jobs
      assert result.run_id == 100
      assert result.url == "https://gl/p/100"
    end

    test "auto at attempt 1 with succeeded jobs that produced no artifacts retries failed jobs" do
      jobs = [
        %{
          "id" => 1,
          "name" => "lint",
          "status" => "success",
          "artifacts" => [%{"file_type" => "trace"}]
        },
        %{"id" => 2, "name" => "test", "status" => "failed"}
      ]

      rerun_stub([failed_pipeline()], jobs, &created(&1, 99))

      assert {:ok, %{mode: :failed_jobs, reused_jobs: ["lint"]}} = Gitlab.rerun_ci(@ref, %{})
      assert_received {:post, @retry_path, _}
    end

    test "auto with succeeded jobs that produced artifacts still starts a fresh MR pipeline" do
      jobs = [
        %{
          "id" => 1,
          "name" => "build",
          "status" => "success",
          "artifacts" => [%{"file_type" => "archive"}, %{"file_type" => "trace"}]
        },
        %{"id" => 2, "name" => "test", "status" => "failed"}
      ]

      rerun_stub([failed_pipeline()], jobs, &created(&1, 100))

      assert {:ok, %{mode: :all_jobs}} = Gitlab.rerun_ci(@ref, %{})
      assert_received {:post, @mr_pipeline_path, _}
    end

    test ":workflow sends inputs as pipeline variables" do
      rerun_stub([failed_pipeline()], [], &created(&1, 101))

      assert {:ok, %{mode: :workflow, run_id: 101}} =
               Gitlab.rerun_ci(@ref, %{mode: :workflow, inputs: %{"force_deploy" => true}})

      assert_received {:post, @new_pipeline_path, body}

      assert %{"ref" => "feat/x", "variables" => [%{"key" => "force_deploy", "value" => "true"}]} =
               Jason.decode!(body)
    end

    test "auto with succeeded upstream jobs picks all_jobs" do
      jobs = [
        %{"id" => 1, "name" => "build", "status" => "success"},
        %{"id" => 2, "name" => "e2e", "status" => "failed"}
      ]

      rerun_stub([failed_pipeline()], jobs, &created(&1, 100))

      assert {:ok, result} = Gitlab.rerun_ci(@ref, %{})
      assert result.mode == :all_jobs
      assert result.reused_jobs == ["build"]
      assert_received {:post, @mr_pipeline_path, _}
    end

    test "auto with an all-failed first attempt picks failed_jobs" do
      jobs = [%{"id" => 2, "name" => "e2e", "status" => "failed"}]
      rerun_stub([failed_pipeline()], jobs, &created(&1, 99))

      assert {:ok, %{mode: :failed_jobs, run_attempt: 1}} = Gitlab.rerun_ci(@ref, %{mode: :auto})
      assert_received {:post, @retry_path, _}
    end

    test "auto at attempt >= 2 (several pipelines on the head SHA) picks all_jobs" do
      jobs = [%{"id" => 2, "name" => "e2e", "status" => "failed"}]
      rerun_stub([failed_pipeline(99), failed_pipeline(98)], jobs, &created(&1, 100))

      assert {:ok, %{mode: :all_jobs, run_attempt: 2}} = Gitlab.rerun_ci(@ref, %{})
    end

    test "inputs with an explicit failed_jobs mode is a validation error" do
      assert {:error, %Error{kind: :validation_failed}} =
               Gitlab.rerun_ci(@ref, %{mode: :failed_jobs, inputs: %{"a" => "b"}})
    end

    test "a head whose latest pipeline is unfinished returns :ci_in_progress, not an error struct" do
      for status <- ["created", "pending", "running", "preparing", "waiting_for_resource"] do
        rerun_stub([%{failed_pipeline() | "status" => status}], [], & &1)
        assert {:error, :ci_in_progress} = Gitlab.rerun_ci(@ref, %{})
      end
    end

    test "an older failed pipeline on the head SHA does not mask a newer unfinished one" do
      rerun_stub(
        [%{failed_pipeline(100) | "status" => "created"}, failed_pipeline(99)],
        [],
        fn _ -> flunk("must not re-run while the newest pipeline is unfinished") end
      )

      assert {:error, :ci_in_progress} = Gitlab.rerun_ci(@ref, %{})
      refute_received {:post, _, _}
    end

    test "a settled non-failure (success) is still a plain not_found error" do
      rerun_stub([%{failed_pipeline() | "status" => "success"}], [], & &1)
      assert {:error, %Error{kind: :not_found}} = Gitlab.rerun_ci(@ref, %{})
    end

    test "errors when no pipeline matches the head SHA" do
      rerun_stub([%{failed_pipeline() | "sha" => "old"}], [], & &1)
      assert {:error, %Error{kind: :not_found}} = Gitlab.rerun_ci(@ref, %{})
    end

    test "an unknown mode is rejected" do
      assert {:error, %Error{kind: :validation_failed}} = Gitlab.rerun_ci(@ref, %{mode: :bogus})
    end

    test ":all_jobs creates the first pipeline when the head has none (#918)" do
      rerun_stub([], [], &created(&1, 101))

      assert {:ok, %{mode: :all_jobs, run_id: 101}} = Gitlab.rerun_ci(@ref, %{mode: :all_jobs})
      assert_received {:post, @mr_pipeline_path, _}
    end

    test ":workflow creates a branch pipeline when the head has none (#918)" do
      rerun_stub([], [], &created(&1, 102))

      assert {:ok, %{mode: :workflow, run_id: 102}} = Gitlab.rerun_ci(@ref, %{mode: :workflow})
      assert_received {:post, @new_pipeline_path, raw}
      assert Jason.decode!(raw)["ref"] == "feat/x"
    end

    test ":auto with no pipeline stays a not_found error" do
      rerun_stub([], [], & &1)
      assert {:error, %Error{kind: :not_found}} = Gitlab.rerun_ci(@ref, %{})
      refute_received {:post, _, _}
    end

    test "a workflow:rules refusal comes back as :pipeline_refused with GitLab's message" do
      refuse = fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "message" => %{
            "base" => ["The pipeline did not run. Review the workflow:rules configuration"]
          }
        })
      end

      rerun_stub([], [], refuse)

      assert {:error, %Error{kind: :pipeline_refused, message: message}} =
               Gitlab.rerun_ci(@ref, %{mode: :all_jobs})

      assert message =~ "The pipeline did not run. Review the workflow:rules configuration"
    end
  end
end
