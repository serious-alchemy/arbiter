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

  describe "credo_files/2" do
    test "with no readable .credo.exs, defaults to lib/ and test/ (root and apps/*/)" do
      files = [
        "lib/a.ex",
        "apps/x/lib/b.ex",
        "test/tonic/device_keys_test.exs",
        "apps/x/test/b_test.exs",
        "apps/x/mix.exs",
        "config/runtime.exs",
        "apps/x/lib/c.md"
      ]

      assert Touched.credo_files(files) == [
               "lib/a.ex",
               "apps/x/lib/b.ex",
               "test/tonic/device_keys_test.exs",
               "apps/x/test/b_test.exs"
             ]
    end

    test "honors the repo's .credo.exs files.included (lib-only keeps tests out)", %{tmp_dir: dir} do
      write(dir, ".credo.exs", """
      %{configs: [%{name: "default", files: %{included: ["lib/", "apps/*/lib/"], excluded: [~r"/_build/"]}}]}
      """)

      files = ["lib/a.ex", "apps/x/lib/b.ex", "test/a_test.exs", "apps/x/test/b_test.exs"]
      assert Touched.credo_files(files, dir) == ["lib/a.ex", "apps/x/lib/b.ex"]
    end

    test "a repo whose .credo.exs lints test/ gets touched test files (tonic case)", %{
      tmp_dir: dir
    } do
      write(dir, ".credo.exs", """
      %{configs: [%{name: "default", files: %{included: ["lib/", "test/"], excluded: []}}]}
      """)

      files = ["lib/tonic/a.ex", "test/tonic_web/live/rbac_enforcement_test.exs", "mix.exs"]

      assert Touched.credo_files(files, dir) == [
               "lib/tonic/a.ex",
               "test/tonic_web/live/rbac_enforcement_test.exs"
             ]
    end

    test "brace globs, zero-depth **/, bare dir names and excluded entries", %{tmp_dir: dir} do
      write(dir, ".credo.exs", ~s|%{configs: [%{files: %{included: ["lib/**/*.{ex,exs}"]}}]}|)

      assert Touched.credo_files(["lib/a/b.ex", "lib/c.exs", "libx/d.ex"], dir) ==
               ["lib/a/b.ex", "lib/c.exs"]

      write(dir, ".credo.exs", ~s|%{configs: [%{files: %{included: ["src/**/*.ex"]}}]}|)
      assert Touched.credo_files(["src/x.ex", "src/a/y.ex"], dir) == ["src/x.ex", "src/a/y.ex"]

      write(dir, ".credo.exs", ~s|%{configs: [%{files: %{included: ["lib"]}}]}|)
      assert Touched.credo_files(["lib/x.ex", "lib_extra/x.ex"], dir) == ["lib/x.ex"]

      write(dir, ".credo.exs", """
      %{configs: [%{files: %{included: ["lib/", "test/"], excluded: [~r"/gen/", "test/fixtures/"]}}]}
      """)

      assert Touched.credo_files(["lib/gen/a.ex", "test/fixtures/b.exs", "test/c_test.exs"], dir) ==
               ["test/c_test.exs"]
    end

    test "supports file globs; a config with no included list falls back to the default", %{
      tmp_dir: dir
    } do
      write(dir, ".credo.exs", ~s|%{configs: [%{files: %{included: ["src/**/*.ex"]}}]}|)
      assert Touched.credo_files(["src/a/b.ex", "src/c.exs", "lib/x.ex"], dir) == ["src/a/b.ex"]

      write(dir, ".credo.exs", "%{configs: []}")

      assert Touched.credo_files(["lib/x.ex", "test/y_test.exs", "z.ex"], dir) ==
               ["lib/x.ex", "test/y_test.exs"]
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
