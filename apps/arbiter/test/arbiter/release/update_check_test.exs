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
end
