defmodule Arbiter.Worker.VisualBaselines.DriftTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.VisualBaselines.Config
  alias Arbiter.Worker.VisualBaselines.Drift

  @moduletag :tmp_dir

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

    String.trim(out)
  end

  defp write(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit(dir, files, message) do
    Enum.each(files, fn {rel, content} -> write(dir, rel, content) end)
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", message])
    git(dir, ["rev-parse", "HEAD"])
  end

  defp config(overrides \\ %{}) do
    {:ok, c} =
      Config.validate(
        Map.merge(
          %{"job" => "visual", "baseline_dir" => "e2e", "ignore_paths" => ["docs/**", "**/*.md"]},
          overrides
        )
      )

    c
  end

  # main: base. branch (feature): an own UI change, "green" there.
  setup %{tmp_dir: dir} do
    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["config", "user.email", "t@example.com"])
    git(dir, ["config", "user.name", "T"])
    git(dir, ["config", "commit.gpgsign", "false"])

    base =
      commit(
        dir,
        [
          {"src/page.html", "<p>one</p>\n<p>two</p>\n<p>three</p>\n"},
          {"src/other.html", "other\n"},
          {"e2e/page-chromium-linux.png", "img0"}
        ],
        "base"
      )

    git(dir, ["checkout", "-q", "-b", "feature"])
    green = commit(dir, [{"src/other.html", "other, edited by the branch\n"}], "branch change")
    git(dir, ["checkout", "-q", "main"])
    main = commit(dir, [{"src/page.html", "<p>one</p>\n<p>two</p>\n<p>3</p>\n"}], "main moved")
    git(dir, ["checkout", "-q", "feature"])

    %{dir: dir, base: base, green: green, main: main}
  end

  test "a merge of main after the green run, with no own change since, is drift", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])
    head = git(ctx.dir, ["rev-parse", "HEAD"])

    assert Drift.decide(ctx.dir, ctx.main, head, ctx.green, config()) == :ok
  end

  test "a rebase onto main (history rewritten, green no longer an ancestor) is drift", ctx do
    git(ctx.dir, ["rebase", "-q", "main"])
    head = git(ctx.dir, ["rev-parse", "HEAD"])

    {_, ancestor} =
      System.cmd("git", ["-C", ctx.dir, "merge-base", "--is-ancestor", ctx.green, head])

    assert ancestor != 0

    assert Drift.decide(ctx.dir, ctx.main, head, ctx.green, config()) == :ok
  end

  test "an own commit to a rendering file after the green run stops it", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])
    head = commit(ctx.dir, [{"src/other.html", "other, changed again\n"}], "own change")

    assert {:skip, {:own_changes, ["src/other.html"]}} =
             Drift.decide(ctx.dir, ctx.main, head, ctx.green, config())
  end

  test "an own commit that edits a page main also moved is not drift either", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])
    head = commit(ctx.dir, [{"src/page.html", "<p>one</p>\n<p>mine</p>\n<p>3</p>\n"}], "own")

    assert {:skip, {:own_changes, ["src/page.html"]}} =
             Drift.decide(ctx.dir, ctx.main, head, ctx.green, config())
  end

  test "own commits to ignored paths and to the baselines themselves do not stop it", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])

    head =
      commit(
        ctx.dir,
        [
          {"docs/notes.md", "notes\n"},
          {"README.md", "readme\n"},
          {"e2e/page-chromium-linux.png", "img-by-the-branch"}
        ],
        "docs and baselines"
      )

    assert Drift.decide(ctx.dir, ctx.main, head, ctx.green, config()) == :ok
  end

  test "undecidable inputs are refused", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])
    head = git(ctx.dir, ["rev-parse", "HEAD"])

    assert {:skip, :no_green_run} = Drift.decide(ctx.dir, ctx.main, head, nil, config())

    assert {:skip, :green_unavailable} =
             Drift.decide(ctx.dir, ctx.main, head, String.duplicate("a", 40), config())

    assert {:skip, :head_is_green} =
             Drift.decide(ctx.dir, ctx.main, ctx.green, ctx.green, config())
  end

  test "a head with the same tree as the green run changed nothing: a flake, not drift", ctx do
    git(ctx.dir, ["commit", "-q", "--allow-empty", "-m", "empty"])
    head = git(ctx.dir, ["rev-parse", "HEAD"])

    assert {:skip, :no_change_since_green} =
             Drift.decide(ctx.dir, ctx.main, head, ctx.green, config())
  end

  test "a head that is itself an auto-refresh commit is never refreshed again", ctx do
    git(ctx.dir, ["merge", "-q", "--no-edit", "main"])
    head = commit(ctx.dir, [{"e2e/page-chromium-linux.png", "img1"}], Drift.refresh_subject())

    assert {:skip, :already_refreshed} =
             Drift.decide(ctx.dir, ctx.main, head, ctx.green, config())
  end

  describe "glob_match?/2" do
    test "** crosses directories, * does not" do
      assert Drift.glob_match?("docs/**", "docs/a/b.md")
      assert Drift.glob_match?("**/*.md", "README.md")
      assert Drift.glob_match?("**/*.md", "a/b/README.md")
      assert Drift.glob_match?("*.md", "README.md")
      refute Drift.glob_match?("*.md", "a/README.md")
      refute Drift.glob_match?("docs/**", "src/docs/a.md")
    end
  end
end
