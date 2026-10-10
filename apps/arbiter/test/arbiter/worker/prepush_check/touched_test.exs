defmodule Arbiter.Worker.PrepushCheck.TouchedTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.PrepushCheck.Touched

  @moduletag :tmp_dir

  defp git(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp write(dir, path, body \\ "x\n") do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  setup %{tmp_dir: dir} do
    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["config", "user.email", "t@example.com"])
    git(dir, ["config", "user.name", "T"])
    git(dir, ["config", "commit.gpgsign", "false"])
    write(dir, "README.md")
    write(dir, "apps/a/lib/a/thing.ex")
    write(dir, "apps/a/test/a/thing_test.exs")
    write(dir, "apps/a/lib/a/untested.ex")
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", "seed"])
    git(dir, ["checkout", "-q", "-b", "work"])
    :ok
  end

  describe "files/2" do
    test "lists the files the branch changed against the target, existing ones only", %{
      tmp_dir: dir
    } do
      write(dir, "apps/a/lib/a/thing.ex", "changed\n")
      write(dir, "apps/a/lib/a/new.ex")
      write(dir, "docs/note with space.md")
      git(dir, ["rm", "-q", "apps/a/lib/a/untested.ex"])
      git(dir, ["add", "-A"])
      git(dir, ["commit", "-q", "-m", "work"])

      assert {:ok, files} = Touched.files(dir, "main")

      assert files == [
               "apps/a/lib/a/new.ex",
               "apps/a/lib/a/thing.ex",
               "docs/note with space.md"
             ]
    end

    test "an unresolvable target is :unknown, not an error", %{tmp_dir: dir} do
      assert Touched.files(dir, "no-such-branch") == :unknown
      assert Touched.files(dir, nil) == :unknown
    end

    test "a branch with no changes is an empty list", %{tmp_dir: dir} do
      assert Touched.files(dir, "main") == {:ok, []}
    end
  end

  describe "elixir_files/1" do
    test "keeps .ex and .exs only" do
      assert Touched.elixir_files(["a.ex", "b.exs", "c.md", "d.heex"]) == ["a.ex", "b.exs"]
    end
  end

  describe "test_files/2" do
    test "maps lib modules to existing tests, keeps changed tests, drops the unmapped", %{
      tmp_dir: dir
    } do
      files = [
        "apps/a/lib/a/thing.ex",
        "apps/a/lib/a/untested.ex",
        "apps/a/test/a/other_test.exs",
        "README.md"
      ]

      write(dir, "apps/a/test/a/other_test.exs")

      assert Touched.test_files(files, dir) == [
               "apps/a/test/a/other_test.exs",
               "apps/a/test/a/thing_test.exs"
             ]
    end

    test "a deleted test is not run", %{tmp_dir: dir} do
      assert Touched.test_files(["apps/a/test/a/gone_test.exs"], dir) == []
    end
  end

  describe "quote_args/1" do
    test "single-quotes each path so spaces and metacharacters are inert" do
      assert Touched.quote_args(["a b.ex", "it's.ex"]) == "'a b.ex' 'it'\\''s.ex'"
    end
  end
end
