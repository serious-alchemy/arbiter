defmodule Arbiter.Sessions.Memory.VerdictsTest do
  use ExUnit.Case, async: true

  import Arbiter.Test.MemoryFixture

  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, root: Path.join(tmp_dir, "memory")}
  end

  defp verdict_for(contents, status) do
    %{Staleness.verify_contents(contents, checkouts: [], ticket_prefixes: []) | status: status}
  end

  test "a written verdict reads back with the same shape", %{root: root} do
    contents = memory("reference", "See https://example.com/x and lib/a.ex:1.")
    verdict = Staleness.verify_contents(contents, checkouts: [], ticket_prefixes: [])

    assert :ok = Verdicts.write(root, "ref.md", verdict)
    assert {:ok, read} = Verdicts.read(root, "ref.md")

    assert read.status == :unverified
    assert read.content_sha256 == verdict.content_sha256
    assert read.citations == verdict.citations
    assert DateTime.compare(read.checked_at, verdict.checked_at) == :eq
  end

  test "no verdict, or an unreadable one, reads as :none", %{root: root} do
    assert Verdicts.read(root, "missing.md") == :none

    File.mkdir_p!(Path.dirname(Verdicts.path(root, "junk.md")))
    File.write!(Verdicts.path(root, "junk.md"), ~s({"status": "maybe"}))
    assert Verdicts.read(root, "junk.md") == :none
  end

  describe "servable?/3" do
    test "only a current, non-stale verdict for the exact bytes serves", %{root: root} do
      contents = memory("project", "body")

      refute Verdicts.servable?(root, "p.md", contents)

      Verdicts.write(root, "p.md", verdict_for(contents, :ok))
      assert Verdicts.servable?(root, "p.md", contents)
      refute Verdicts.servable?(root, "p.md", contents <> "edited\n")

      Verdicts.write(root, "p.md", verdict_for(contents, :unverified))
      assert Verdicts.servable?(root, "p.md", contents)

      Verdicts.write(root, "p.md", verdict_for(contents, :stale))
      refute Verdicts.servable?(root, "p.md", contents)
    end
  end

  test "delete/2 removes a verdict and tolerates a missing one", %{root: root} do
    Verdicts.write(root, "d.md", verdict_for(memory("user", "x"), :ok))

    assert :ok = Verdicts.delete(root, "d.md")
    assert Verdicts.read(root, "d.md") == :none
    assert :ok = Verdicts.delete(root, "d.md")
  end
end
