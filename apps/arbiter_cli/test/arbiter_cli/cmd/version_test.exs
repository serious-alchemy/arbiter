defmodule ArbiterCli.Cmd.VersionTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Version

  # Server version with SHA matching the compiled CLI — no mismatch expected.
  defp matching_server_version do
    %{
      "version" => "0.1.0",
      "sha" => ArbiterCli.Version.git_sha_clean(),
      "built_at" => "2024-01-01T00:00:00Z",
      "booted_at" => "2024-01-01T00:01:00Z"
    }
  end

  @mismatched_server_version %{
    "version" => "0.1.0",
    "sha" => "abc1234",
    "built_at" => "2024-01-01T00:00:00Z",
    "booted_at" => "2024-01-01T00:01:00Z"
  }

  test "prints CLI and server versions when server is reachable" do
    stub_get("/api/version", matching_server_version())

    {out, _err, exit_code} = capture(fn -> Version.run([]) end)
    assert exit_code == 0
    assert out =~ "CLI escript"
    assert out =~ "version:"
    assert out =~ "sha:"
    assert out =~ "built-at:"
    assert out =~ "Server"
    assert out =~ "booted-at:"
    refute out =~ "WARNING"
  end

  test "flags a SHA mismatch loudly" do
    stub_get("/api/version", @mismatched_server_version)

    {out, _err, exit_code} = capture(fn -> Version.run([]) end)
    assert exit_code == 0
    assert out =~ "WARNING"
    assert out =~ "different builds"
  end

  test "prints CLI version and degraded server block when server unreachable" do
    stub_transport_error(:get, "/api/version", :econnrefused)

    {out, _err, exit_code} = capture(fn -> Version.run([]) end)
    assert exit_code == 0
    assert out =~ "CLI escript"
    assert out =~ "Server"
    assert out =~ "unreachable"
    refute out =~ "WARNING"
  end

  test "--json emits structured output with sha_mismatch false when SHAs match" do
    stub_get("/api/version", matching_server_version())

    {out, _err, exit_code} = capture(fn -> Version.run(["--json"]) end)
    assert exit_code == 0

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert Map.has_key?(payload, "cli")
    assert Map.has_key?(payload, "server")
    assert payload["sha_mismatch"] == false
    assert is_binary(payload["cli"]["version"])
  end

  test "--json emits sha_mismatch true when SHAs differ" do
    stub_get("/api/version", @mismatched_server_version)

    {out, _err, exit_code} = capture(fn -> Version.run(["--json"]) end)
    assert exit_code == 0

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["sha_mismatch"] == true
  end

  test "--json marks server as unreachable when server is down" do
    stub_transport_error(:get, "/api/version", :econnrefused)

    {out, _err, exit_code} = capture(fn -> Version.run(["--json"]) end)
    assert exit_code == 0

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["server"]["status"] == "unreachable"
    assert payload["sha_mismatch"] == nil
  end

  test "announces a newer release when the server reports one" do
    update = %{
      "update_available" => true,
      "latest" => "v0.3.0",
      "release_url" => "https://example.test/r/v0.3.0"
    }

    stub_get("/api/version", Map.put(matching_server_version(), "update", update))

    {out, _err, 0} = capture(fn -> Version.run([]) end)
    assert out =~ "UPDATE AVAILABLE: v0.3.0"
    assert out =~ "arb server deploy"
    assert out =~ "https://example.test/r/v0.3.0"
  end

  test "surfaces a failed update check without the banner" do
    update = %{"update_available" => false, "error" => "GitHub Releases API returned HTTP 403"}
    stub_get("/api/version", Map.put(matching_server_version(), "update", update))

    {out, _err, 0} = capture(fn -> Version.run([]) end)
    refute out =~ "UPDATE AVAILABLE"
    assert out =~ "update check: failed"
  end

  test "--json passes the update block through" do
    update = %{"update_available" => true, "latest" => "v0.3.0"}
    stub_get("/api/version", Map.put(matching_server_version(), "update", update))

    {out, _err, 0} = capture(fn -> Version.run(["--json"]) end)
    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["server"]["update"]["latest"] == "v0.3.0"
  end
end
