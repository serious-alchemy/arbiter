defmodule Arbiter.Sessions.Memory.CitationsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Memory.Citations

  describe "files/1" do
    test "extracts repo-relative file:line citations, ranges anchored on the first line" do
      body = """
      See lib/foo.ex:12, (apps/arbiter/lib/x.ex:83-88) and `test/y_test.exs:4`.
      Again lib/foo.ex:12.
      """

      assert Citations.files(body) == [
               %{ref: "lib/foo.ex:12", path: "lib/foo.ex", line: 12},
               %{ref: "apps/arbiter/lib/x.ex:83", path: "apps/arbiter/lib/x.ex", line: 83},
               %{ref: "test/y_test.exs:4", path: "test/y_test.exs", line: 4}
             ]
    end

    test "ignores host:port, bare filenames, URLs, absolute and parent-relative paths" do
      body = """
      Server on 127.0.0.1:4848 and example.com:443; a bare memory.ex:81;
      https://github.com/o/r/blob/main/lib/foo.ex:12; /etc/passwd:1;
      ../outside/secret.ex:3 and lib/../../escape.ex:9.
      """

      assert Citations.files(body) == []
    end
  end

  describe "modules/1" do
    test "extracts dotted module names once, without the function suffix" do
      body =
        "Call Arbiter.Sessions.Memory.mount/2 — Arbiter.Sessions.Memory again, Ecto.Changeset."

      assert Citations.modules(body) == ["Arbiter.Sessions.Memory", "Ecto.Changeset"]
    end

    test "ignores single-segment names" do
      assert Citations.modules("Arbiter and Phoenix are names, not citations.") == []
    end
  end

  describe "tickets/2" do
    test "extracts ids with a known prefix and at least one digit" do
      body = "Fixed in bd-19qve3#review and vs-a0iy5k; see bd-6dkpf1's notes."

      assert Citations.tickets(body, ["bd", "vs"]) == ["bd-19qve3", "vs-a0iy5k", "bd-6dkpf1"]
    end

    test "skips digitless ids, unknown prefixes and ordinary hyphenated words" do
      body = "bd-cyxzvq, vs-code, xx-12345, re-use, a bd-1 too short."

      assert Citations.tickets(body, ["bd", "vs"]) == []
    end

    test "with no prefixes, nothing is a ticket" do
      assert Citations.tickets("bd-19qve3", []) == []
    end
  end

  describe "urls/1" do
    test "extracts http(s) URLs" do
      body = "Docs at https://example.com/a?b=1 and (http://localhost:4848/x)."

      assert Citations.urls(body) == ["https://example.com/a?b=1", "http://localhost:4848/x"]
    end
  end
end
