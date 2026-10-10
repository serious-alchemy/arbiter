defmodule Arbiter.Worker.TestReportTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.TestReport

  @passing """
  Compiling 3 files (.ex)
  warning: variable "x" is unused
    lib/foo.ex:3

  ...............................
  Finished in 0.4 seconds (0.2s async, 0.2s sync)
  31 tests, 0 failures

  Randomized with seed 123
  """

  @failing """
  Running ExUnit with seed: 1, max_cases: 4

  ..

    1) test adds numbers (Arbiter.MathTest)
       test/arbiter/math_test.exs:7
       Assertion with == failed
       code:  assert Math.add(1, 2) == 4
       left:  3
       right: 4
       stacktrace:
         test/arbiter/math_test.exs:8: (test)
         (ex_unit 1.18.0) lib/ex_unit/runner.ex:1: anything/1
         (ex_unit 1.18.0) lib/ex_unit/runner.ex:2: anything/2
         (ex_unit 1.18.0) lib/ex_unit/runner.ex:3: anything/3
         (ex_unit 1.18.0) lib/ex_unit/runner.ex:4: anything/4

    2) test raises (Arbiter.MathTest)
       test/arbiter/math_test.exs:12
       ** (ArgumentError) boom
       code: Math.boom()
       stacktrace:
         (arbiter 0.1.0) lib/arbiter/math.ex:9: Arbiter.Math.boom/0
         test/arbiter/math_test.exs:13: (test)

  Finished in 0.1 seconds (0.1s async, 0.0s sync)
  5 tests, 2 failures, 1 skipped

  Randomized with seed 1
  """

  describe "build/3 on a green run" do
    test "returns counts only, none of the run's output" do
      report = TestReport.build(@passing, 0)

      assert report.status == :passed
      assert report.tests == 31
      assert report.failures == 0
      assert report.failed_tests == []
      assert report.summary =~ "31 tests, 0 failures"
      refute inspect(report) =~ "unused"
    end

    test "sums the summary lines of several umbrella apps" do
      out = "1 doctest, 4 tests, 0 failures\n\n10 tests, 0 failures\n"
      report = TestReport.build(out, 0)

      assert report.tests == 15
      assert report.failures == 0
    end
  end

  describe "build/3 on a red run" do
    test "keeps every failing test's header and assertion" do
      report = TestReport.build(@failing, 2)

      assert report.status == :failed
      assert report.tests == 5
      assert report.failures == 2
      assert report.skipped == 1
      assert [first, second] = report.failed_tests

      assert first =~ "1) test adds numbers (Arbiter.MathTest)"
      assert first =~ "test/arbiter/math_test.exs:7"
      assert first =~ "left:  3"
      assert first =~ "right: 4"
      assert second =~ "2) test raises (Arbiter.MathTest)"
      assert second =~ "** (ArgumentError) boom"
    end

    test "trims the stacktrace to a few frames" do
      [first | _] = TestReport.build(@failing, 2).failed_tests

      assert first =~ "test/arbiter/math_test.exs:8: (test)"
      refute first =~ "anything/4"
    end

    test "drops passing-test dots and the seed chatter" do
      text = TestReport.render(TestReport.build(@failing, 2))

      refute text =~ "Randomized with seed"
      refute text =~ "Running ExUnit"
    end

    test "is capped, yet every header survives a tight cap" do
      many =
        for n <- 1..30, into: "" do
          """

            #{n}) test case #{n} (Arbiter.BigTest)
               test/big_test.exs:#{n}
               Assertion with == failed
               code:  assert #{String.duplicate("x", 300)}
               left:  1
               right: 2
               stacktrace:
                 test/big_test.exs:#{n}: (test)
          """
        end

      out = many <> "\n30 tests, 30 failures\n"
      report = TestReport.build(out, 2, limit: 3000)
      text = TestReport.render(report)

      assert String.length(text) <= 4500

      for n <- 1..30 do
        assert text =~ "#{n}) test case #{n} (Arbiter.BigTest)"
      end
    end

    test "strips ANSI colour codes" do
      out = "  1) test a (T)\n     \e[31mtest/a_test.exs:1\e[0m\n\n1 test, 1 failure\n"
      [block] = TestReport.build(out, 2).failed_tests

      refute block =~ "\e["
      assert block =~ "test/a_test.exs:1"
    end
  end

  describe "build/3 on runs that never reached a summary" do
    test "a compile error comes back as an error with the relevant excerpt" do
      out = """
      Compiling 1 file (.ex)
      == Compilation error in file lib/foo.ex ==
      ** (CompileError) lib/foo.ex:3: undefined function bar/0
      """

      report = TestReport.build(out, 1)

      assert report.status == :error
      assert report.tests == nil
      assert report.excerpt =~ "CompileError"
    end

    test "a timeout is reported as such, with the output tail" do
      report = TestReport.build("lots\nof\noutput\n", 124)

      assert report.status == :timeout
      assert report.excerpt =~ "output"
    end

    test "a non-zero exit with zero failures is an error, not a pass" do
      report = TestReport.build("3 tests, 0 failures\n", 2)

      assert report.status == :error
    end
  end

  describe "render/1" do
    test "a green run is one line" do
      text = TestReport.render(TestReport.build(@passing, 0))

      assert text =~ "passed"
      assert text =~ "31 tests"
      refute text =~ "\n"
    end
  end
end
