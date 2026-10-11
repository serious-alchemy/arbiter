defmodule Arbiter.Loop.Replay.ScoreTest do
  @moduledoc """
  bd-c7lx65 (R15, `docs/design/paced-quota-routing-signals.md` §7.2): scoring a
  replay against the known-good result. The main score is the reviewer's
  round-1 verdict, read exactly as the live ReviewGate records `converged`;
  tests and diff overlap with the merged change are secondary.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Replay.Score

  @acceptance "- The thing works.\n- It is tested."

  @met """
  VERDICT: APPROVE

  CRITERIA:
  - [MET] The thing works — lib/thing.ex:12
  - [MET] It is tested — test/thing_test.exs:4

  arb done
  """

  @unmet """
  VERDICT: APPROVE

  CRITERIA:
  - [MET] The thing works — lib/thing.ex:12
  - [NOT MET] It is tested — no test touches the new branch

  arb done
  """

  defp lines(text), do: String.split(text, "\n")

  describe "verdict/1" do
    test "reads the first VERDICT line and keeps what follows as the findings" do
      assert {:approve, findings} = Score.verdict(lines("thinking...\n" <> @met))
      assert findings =~ "[MET] It is tested"
      refute findings =~ "thinking"
    end

    test "a REQUEST_CHANGES verdict" do
      out = "VERDICT: REQUEST_CHANGES\n1. [High] lib/thing.ex:3 — crashes on nil. Fix: guard it."
      assert {:request_changes, findings} = Score.verdict(lines(out))
      assert findings =~ "crashes on nil"
    end

    test "no sentinel is :no_verdict" do
      assert {:no_verdict, ""} = Score.verdict(lines("I looked at it and it seems fine."))
    end
  end

  describe "converged?/1 — the live ReviewGate's round-1 rule" do
    test "an APPROVE that meets every stated criterion on a non-empty diff converges" do
      assert Score.converged?(%{
               verdict: :approve,
               findings: @met,
               acceptance: @acceptance,
               net_diff_empty?: false
             })
    end

    test "an APPROVE whose breakdown admits a [NOT MET] criterion does not" do
      refute Score.converged?(%{
               verdict: :approve,
               findings: @unmet,
               acceptance: @acceptance,
               net_diff_empty?: false
             })
    end

    test "an APPROVE with no criteria breakdown on a ticket that states criteria does not" do
      refute Score.converged?(%{
               verdict: :approve,
               findings: "VERDICT: APPROVE\nLooks good.",
               acceptance: @acceptance,
               net_diff_empty?: false
             })
    end

    test "a ticket with no acceptance criteria needs no breakdown" do
      for acceptance <- [nil, "", "  ", "(none)"] do
        assert Score.converged?(%{
                 verdict: :approve,
                 findings: "VERDICT: APPROVE\nLooks good.",
                 acceptance: acceptance,
                 net_diff_empty?: false
               }),
               "acceptance #{inspect(acceptance)}"
      end
    end

    test "an APPROVE of an empty net diff does not converge" do
      refute Score.converged?(%{
               verdict: :approve,
               findings: @met,
               acceptance: @acceptance,
               net_diff_empty?: true
             })
    end

    test "REQUEST_CHANGES and no verdict never converge" do
      for verdict <- [:request_changes, :no_verdict] do
        refute Score.converged?(%{
                 verdict: verdict,
                 findings: @met,
                 acceptance: @acceptance,
                 net_diff_empty?: false
               })
      end
    end
  end

  describe "added_lines/1" do
    test "takes the added lines of a unified diff, trimmed, without the file headers" do
      patch = """
      diff --git a/lib/thing.ex b/lib/thing.ex
      index 1111111..2222222 100644
      --- a/lib/thing.ex
      +++ b/lib/thing.ex
      @@ -1,3 +1,4 @@
       defmodule Thing do
      -  def old, do: :old
      +  def new(x), do: {:ok, x}
      +
      +  end
      """

      assert Score.added_lines(patch) == MapSet.new(["def new(x), do: {:ok, x}"])
    end

    test "an empty patch has no lines" do
      assert Score.added_lines("") == MapSet.new()
    end
  end

  describe "overlap/2" do
    test "the same change overlaps completely" do
      change = %{files: ["lib/a.ex", "lib/b.ex"], patch: "+  value = compute(input)\n"}
      assert %{files: 1.0, lines: 1.0} = Score.overlap(change, change)
    end

    test "is the Jaccard index of the touched files and of the added lines" do
      replay = %{
        files: ["lib/a.ex", "lib/b.ex"],
        patch: "+  value = compute(input)\n+  log(value, :debug)\n"
      }

      known_good = %{
        files: ["lib/b.ex", "lib/c.ex"],
        patch: "+  value = compute(input)\n+  Logger.info(inspect(value))\n"
      }

      assert %{files: files, lines: lines} = Score.overlap(replay, known_good)
      assert_in_delta files, 1 / 3, 1.0e-9
      assert_in_delta lines, 1 / 3, 1.0e-9
    end

    test "a replay that changed nothing overlaps not at all" do
      known_good = %{files: ["lib/a.ex"], patch: "+  value = compute(input)\n"}
      assert %{files: +0.0, lines: +0.0} = Score.overlap(%{files: [], patch: ""}, known_good)
    end

    test "nothing on either side is undefined, not perfect" do
      empty = %{files: [], patch: ""}
      assert %{files: nil, lines: nil} = Score.overlap(empty, empty)
    end
  end
end
