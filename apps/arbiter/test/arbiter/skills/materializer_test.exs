defmodule Arbiter.Skills.MaterializerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Skills.Materializer
  alias Arbiter.Skills.Skill

  setup do
    tmp = Path.join(System.tmp_dir!(), "mat-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp resolved(name, body, activation \\ :situational, metadata \\ %{}) do
    %{
      skill: %Skill{name: name, body: body, activation_mode: activation, metadata: metadata},
      activation: activation
    }
  end

  describe "materialize/2" do
    test "writes only the resolved set to .claude/skills/<name>/SKILL.md", %{tmp: tmp} do
      set = [resolved("tdd", "# TDD body"), resolved("debug", "# Debug body")]

      assert {:ok, written} = Materializer.materialize(tmp, set)
      assert Enum.sort(written) == ["debug", "tdd"]

      assert File.read!(Path.join(tmp, ".claude/skills/tdd/SKILL.md")) == "# TDD body"
      assert File.read!(Path.join(tmp, ".claude/skills/debug/SKILL.md")) == "# Debug body"

      # Nothing else leaked in.
      assert Path.wildcard(Path.join(tmp, ".claude/skills/*"))
             |> Enum.map(&Path.basename/1)
             |> Enum.sort() ==
               ["debug", "tdd"]
    end

    test "adds the skills tree to the worktree git exclude", %{tmp: tmp} do
      {_, 0} = System.cmd("git", ["init", "-q", tmp])

      assert {:ok, _} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")])

      exclude = File.read!(Path.join(tmp, ".git/info/exclude"))
      assert exclude =~ ".claude/skills/"
    end

    test "nil worktree is a no-op" do
      assert Materializer.materialize(nil, [resolved("tdd", "# TDD")]) == {:ok, []}
    end

    test "empty set is a no-op", %{tmp: tmp} do
      assert Materializer.materialize(tmp, []) == {:ok, []}
      refute File.exists?(Path.join(tmp, ".claude"))
    end

    test "writes to .agents/skills for the gemini provider", %{tmp: tmp} do
      set = [resolved("tdd", "# TDD body")]

      assert {:ok, ["tdd"]} = Materializer.materialize(tmp, set, :gemini)

      assert File.read!(Path.join(tmp, ".agents/skills/tdd/SKILL.md")) == "# TDD body"
      refute File.exists?(Path.join(tmp, ".claude/skills/tdd"))
    end

    test "excludes .agents/skills from git for the gemini provider", %{tmp: tmp} do
      {_, 0} = System.cmd("git", ["init", "-q", tmp])

      assert {:ok, _} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")], :gemini)

      exclude = File.read!(Path.join(tmp, ".git/info/exclude"))
      assert exclude =~ ".agents/skills/"
    end

    test "codex writes nothing — it reads no skills dir; skills go inline in the prompt", %{
      tmp: tmp
    } do
      assert {:ok, []} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")], :codex)
      refute File.exists?(Path.join(tmp, ".claude"))
      refute File.exists?(Path.join(tmp, ".agents"))
    end

    test "an unknown provider keeps the .claude/skills default", %{tmp: tmp} do
      assert {:ok, ["tdd"]} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")], nil)
      assert File.read!(Path.join(tmp, ".claude/skills/tdd/SKILL.md")) == "# TDD"
    end

    test "defaults to :claude when no provider is given", %{tmp: tmp} do
      assert {:ok, ["tdd"]} = Materializer.materialize(tmp, [resolved("tdd", "# TDD")])
      assert File.read!(Path.join(tmp, ".claude/skills/tdd/SKILL.md")) == "# TDD"
    end
  end

  describe "skills_dir/1" do
    test "claude (default) is .claude/skills" do
      assert Materializer.skills_dir() == Path.join(".claude", "skills")
      assert Materializer.skills_dir(:claude) == Path.join(".claude", "skills")
    end

    test "gemini is .agents/skills — agy's documented workspace discovery path" do
      assert Materializer.skills_dir(:gemini) == Path.join(".agents", "skills")
    end

    test "any other provider (nil, unknown) falls back to .claude/skills" do
      assert Materializer.skills_dir(nil) == Path.join(".claude", "skills")
    end
  end

  describe "prompt_section/1" do
    test "empty set → empty string" do
      assert Materializer.prompt_section([]) == ""
    end

    test "always-on skills get an imperative /name directive" do
      section = Materializer.prompt_section([resolved("tdd", "# TDD", :always_on)])

      assert section =~ "Required skills"
      assert section =~ "MUST"
      assert section =~ "/tdd"
    end

    test "situational skills are advertised, not forced" do
      section = Materializer.prompt_section([resolved("debug", "# Debug", :situational)])

      assert section =~ "Available skills"
      assert section =~ "/debug"
      refute section =~ "MUST"
    end

    test "mixed set lists both blocks with descriptions from metadata" do
      set = [
        resolved("tdd", "# TDD", :always_on, %{"description" => "test first"}),
        resolved("debug", "# Debug", :situational)
      ]

      section = Materializer.prompt_section(set)
      assert section =~ "Required skills"
      assert section =~ "Available skills"
      assert section =~ "`/tdd` — test first"
      assert section =~ "/debug"
    end

    test "defaulting materialized?/2 to true preserves the current claude behavior" do
      set = [resolved("tdd", "# TDD body", :always_on)]
      assert Materializer.prompt_section(set) == Materializer.prompt_section(set, true)
    end
  end

  describe "prompt_section/2 when the set was NOT materialized anywhere the provider reads" do
    test "never claims skills are available/materialized in this worktree" do
      set = [resolved("tdd", "# TDD body", :always_on)]

      section = Materializer.prompt_section(set, false)

      refute section =~ "available in this worktree"
      refute section =~ "materialized in this worktree"
    end

    test "always-on skills get their full body inlined instead of just a slash-command name" do
      set = [resolved("tdd", "# TDD body — do the red bit first", :always_on)]

      section = Materializer.prompt_section(set, false)

      assert section =~ "Required skills"
      assert section =~ "MUST"
      assert section =~ "# TDD body — do the red bit first"
    end

    test "situational skills are dropped rather than falsely advertised as available" do
      set = [
        resolved("tdd", "# TDD body", :always_on),
        resolved("debug", "# Debug body", :situational)
      ]

      section = Materializer.prompt_section(set, false)

      refute section =~ "Debug body"
      refute section =~ "/debug"
    end

    test "an always-on-only set with nothing materializable still produces content" do
      set = [resolved("tdd", "# TDD body", :always_on)]
      refute Materializer.prompt_section(set, false) == ""
    end

    test "a situational-only set with nothing materializable produces no content" do
      set = [resolved("debug", "# Debug body", :situational)]
      assert Materializer.prompt_section(set, false) == ""
    end
  end
end
