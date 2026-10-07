defmodule Arbiter.Release.UpdateCheckTest do
  use ExUnit.Case, async: true

  alias Arbiter.Release.UpdateCheck

  describe "newer?/2" do
    test "compares semver numerically, not lexically" do
      assert UpdateCheck.newer?("v0.10.0", "0.9.0")
      assert UpdateCheck.newer?("v0.2.1", "0.2.0")
      refute UpdateCheck.newer?("v0.2.0", "0.2.0")
      refute UpdateCheck.newer?("v0.1.9", "0.2.0")
    end

    test "ignores a leading v on either side" do
      refute UpdateCheck.newer?("v0.2.0", "v0.2.0")
      assert UpdateCheck.newer?("0.3.0", "v0.2.0")
    end

    test "a -published or git-describe suffix on the running version counts as that release" do
      refute UpdateCheck.newer?("v0.2.0", "0.2.0-published")
      assert UpdateCheck.newer?("v0.3.0", "0.2.0-published")
      refute UpdateCheck.newer?("v0.2.0", "0.2.0-5-gabc1234")
      assert UpdateCheck.newer?("v0.2.1", "0.2.0-5-gabc1234")
    end

    test "a pre-release latest tag is never an update" do
      refute UpdateCheck.newer?("v0.3.0-rc1", "0.2.0")
      refute UpdateCheck.newer?("v0.3.0-beta.2", "0.2.0")
    end

    test "unparseable versions are never an update" do
      refute UpdateCheck.newer?("nightly", "0.2.0")
      refute UpdateCheck.newer?("v0.3.0", "unknown")
      refute UpdateCheck.newer?(nil, "0.2.0")
    end
  end

  describe "polling" do
    defp start_check(name, opts) do
      opts =
        Keyword.merge(
          [
            name: name,
            enabled: true,
            repo: "acme/arbiter",
            running_version: "0.2.0",
            initial_delay_ms: :infinity,
            req_options: [plug: {Req.Test, name}]
          ],
          opts
        )

      pid = start_supervised!({UpdateCheck, opts})
      Req.Test.allow(name, self(), pid)
      name
    end

    test "state/1 answers promptly while a check is in flight" do
      name = :"uc_slow_#{System.unique_integer([:positive])}"
      test_pid = self()

      Req.Test.stub(name, fn conn ->
        send(test_pid, {:in_flight, self()})

        receive do
          :release -> Req.Test.json(conn, %{"tag_name" => "v0.3.0", "html_url" => "u"})
        end
      end)

      start_check(name, running_version: "0.2.0")
      caller = Task.async(fn -> UpdateCheck.check_now(name) end)
      # The plug runs in a Task the checker spawns, so on a loaded CI box the
      # message can take longer than assert_receive's 100ms default to arrive.
      # Wait on the signal itself, with a bound only so a real hang fails.
      assert_receive {:in_flight, plug_pid}, 5_000

      state = UpdateCheck.state(name)
      assert state.enabled
      refute state.update_available?

      send(plug_pid, :release)
      assert %{update_available?: true, latest: "v0.3.0"} = Task.await(caller)
      assert %{update_available?: true} = UpdateCheck.state(name)
    end

    test "records an available update" do
      name = :"uc_ok_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{
          "tag_name" => "v0.3.0",
          "html_url" => "https://example.test/r/v0.3.0"
        })
      end)

      start_check(name, running_version: "0.2.0")

      state = UpdateCheck.check_now(name)
      assert state.latest == "v0.3.0"
      assert state.update_available? == true
      assert state.error == nil
      assert state.release_url == "https://example.test/r/v0.3.0"
      assert %DateTime{} = state.checked_at
    end

    test "up-to-date install reports no update" do
      name = :"uc_same_#{System.unique_integer([:positive])}"
      Req.Test.stub(name, &Req.Test.json(&1, %{"tag_name" => "v0.2.0"}))

      start_check(name, running_version: "0.2.0-published")

      assert %{update_available?: false, latest: "v0.2.0", error: nil} =
               UpdateCheck.check_now(name)
    end

    test "rate limit is recorded as last error and keeps the prior result" do
      name = :"uc_rl_#{System.unique_integer([:positive])}"
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(name, fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> Req.Test.json(conn, %{"tag_name" => "v0.3.0"})
          _ -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "rate limit"})
        end
      end)

      start_check(name, running_version: "0.2.0")

      assert %{update_available?: true} = UpdateCheck.check_now(name)
      state = UpdateCheck.check_now(name)
      assert state.error =~ "403"
      assert state.latest == "v0.3.0"
      assert state.update_available? == true
    end

    test "transport errors and malformed bodies are recorded, not raised" do
      name = :"uc_err_#{System.unique_integer([:positive])}"
      Req.Test.stub(name, &Req.Test.transport_error(&1, :econnrefused))

      start_check(name, running_version: "0.2.0")

      assert %{error: err, update_available?: false} = UpdateCheck.check_now(name)
      assert is_binary(err)

      Req.Test.stub(name, &Req.Test.json(&1, %{"nope" => 1}))
      assert %{error: err2} = UpdateCheck.check_now(name)
      assert err2 =~ "tag_name"
    end

    test "a 304 keeps the cached result via ETag" do
      name = :"uc_etag_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, fn conn ->
        case Plug.Conn.get_req_header(conn, "if-none-match") do
          [~s("abc")] ->
            Plug.Conn.send_resp(conn, 304, "")

          _ ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("abc"))
            |> Req.Test.json(%{"tag_name" => "v0.3.0"})
        end
      end)

      start_check(name, running_version: "0.2.0")

      UpdateCheck.check_now(name)

      assert %{latest: "v0.3.0", update_available?: true, error: nil} =
               UpdateCheck.check_now(name)
    end

    test "missing repo is a recorded error" do
      name = :"uc_norepo_#{System.unique_integer([:positive])}"

      start_check(name, repo: nil)

      assert %{error: err} = UpdateCheck.check_now(name)
      assert err =~ "ARB_RELEASE_REPO"
    end
  end

  describe "disabled" do
    test "does not start a process and state/0 reports disabled" do
      name = :"uc_off_#{System.unique_integer([:positive])}"
      assert :ignore = UpdateCheck.start_link(name: name, enabled: false)
      assert %{enabled: false, update_available?: false} = UpdateCheck.state(name)
    end
  end

  describe "migrations_pending" do
    defp start_check_with_manifest(name, manifest_body, applied) do
      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/repos/acme/arbiter/releases/latest" ->
            Req.Test.json(conn, %{
              "tag_name" => "v0.3.0",
              "html_url" => "u",
              "assets" => [
                %{
                  "name" => "arbiter-v0.3.0-migrations.txt",
                  "browser_download_url" => "https://dl.test/m.txt"
                }
              ]
            })

          "/m.txt" ->
            Plug.Conn.send_resp(conn, 200, manifest_body)
        end
      end)

      pid =
        start_supervised!(
          {UpdateCheck,
           name: name,
           enabled: true,
           repo: "acme/arbiter",
           running_version: "0.2.0",
           initial_delay_ms: :infinity,
           applied_migrations: applied,
           req_options: [plug: {Req.Test, name}]}
        )

      Req.Test.allow(name, self(), pid)
      name
    end

    test "names the manifest entries this database has not applied" do
      name = :"uc_mig_#{System.unique_integer([:positive])}"

      manifest = "20260101000000_a\n20260202000000_b\n20260303000000_c\n"

      start_check_with_manifest(name, manifest, fn -> [20_260_101_000_000, 20_260_202_000_000] end)

      state = UpdateCheck.check_now(name)

      assert state.update_available?
      assert state.migrations_pending == ["20260303000000_c"]
    end

    test "an empty pending list means the update does not migrate" do
      name = :"uc_mig_#{System.unique_integer([:positive])}"
      start_check_with_manifest(name, "20260101000000_a\n", fn -> [20_260_101_000_000] end)

      assert UpdateCheck.check_now(name).migrations_pending == []
    end

    test "is unknown (nil) when the release has no manifest" do
      name = :"uc_mig_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, &Req.Test.json(&1, %{"tag_name" => "v0.3.0", "html_url" => "u"}))

      pid =
        start_supervised!(
          {UpdateCheck,
           name: name,
           enabled: true,
           repo: "acme/arbiter",
           running_version: "0.2.0",
           initial_delay_ms: :infinity,
           applied_migrations: fn -> [] end,
           req_options: [plug: {Req.Test, name}]}
        )

      Req.Test.allow(name, self(), pid)

      state = UpdateCheck.check_now(name)
      assert state.update_available?
      assert state.migrations_pending == nil
    end

    test "is unknown when the database cannot be read" do
      name = :"uc_mig_#{System.unique_integer([:positive])}"
      start_check_with_manifest(name, "20260101000000_a\n", fn -> nil end)

      assert UpdateCheck.check_now(name).migrations_pending == nil
    end
  end
end
