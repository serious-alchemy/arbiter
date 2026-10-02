defmodule Arbiter.Sessions.Memory.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.Memory.Frontmatter

  @nested """
  ---
  name: some-slug
  description: a fixture
  metadata:
    type: project
    workspace_id: ws-1
  ---

  Body text.
  """

  describe "fields/1" do
    test "reads top-level and nested keys as strings" do
      assert %{
               "name" => "some-slug",
               "description" => "a fixture",
               "type" => "project",
               "workspace_id" => "ws-1"
             } = Frontmatter.fields(@nested)
    end

    # Round-4 finding 2: the keys come from files a session wrote, so they must
    # never be turned into atoms.
    test "never creates an atom for an unknown key" do
      key = "zz_memory_fm_key_#{System.unique_integer([:positive])}"

      fields = Frontmatter.fields("---\n#{key}: value\n---\nbody\n")

      assert fields[key] == "value"
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "unquotes double-quoted values" do
      assert Frontmatter.fields(~s(---\nreason: "a: b \\"c\\""\n---\n))["reason"] == ~s(a: b "c")
    end

    test "is empty for a file without a frontmatter block" do
      assert Frontmatter.fields("just a body\n") == %{}
      assert Frontmatter.fields("---\nunterminated: yes\n") == %{}
    end
  end

  describe "body/1" do
    test "is the text after the closing delimiter" do
      assert Frontmatter.body(@nested) =~ "Body text."
      refute Frontmatter.body(@nested) =~ "workspace_id"
    end

    test "is the whole text when there is no frontmatter" do
      assert Frontmatter.body("plain\n") == "plain\n"
    end
  end

  describe "put/2" do
    # Round-4 finding 3: adding fields must not rebuild the block, or
    # `metadata:` and its nested `type:` are flattened.
    test "inserts before the closing delimiter and keeps every other line verbatim" do
      updated = Frontmatter.put(@nested, [{"quarantine_sha", "abc123"}])

      assert updated == """
             ---
             name: some-slug
             description: a fixture
             metadata:
               type: project
               workspace_id: ws-1
             quarantine_sha: abc123
             ---

             Body text.
             """
    end

    test "replaces an existing top-level key in place instead of duplicating it" do
      once = Frontmatter.put(@nested, [{"verified_sha", "aaa"}])
      twice = Frontmatter.put(once, [{"verified_sha", "bbb"}])

      assert Frontmatter.fields(twice)["verified_sha"] == "bbb"
      assert length(Regex.scan(~r/verified_sha:/, twice)) == 1
    end

    test "quotes free text and cannot be used to inject lines" do
      updated = Frontmatter.put(@nested, [{"rejection_reason", "bad: claim\n---\ntype: user"}])

      assert Frontmatter.fields(updated)["rejection_reason"] == "bad: claim --- type: user"
      assert Frontmatter.fields(updated)["type"] == "project"
      assert updated =~ ~s(rejection_reason: "bad: claim --- type: user")
    end

    test "prepends a block to a file that has none" do
      assert Frontmatter.put("Content\n", [{"source_session", "s-1"}]) ==
               "---\nsource_session: s-1\n---\nContent\n"
    end
  end

  describe "drop/2" do
    test "removes a key at any indentation together with its children" do
      forged = """
      ---
      name: x
      metadata:
        type: project
        promoted_by: operator
      anchors:
        - "lib/a.ex:1=deadbeefdeadbeef"
        - "lib/b.ex:2=deadbeefdeadbeef"
      description: kept
      ---
      Body
      """

      dropped = Frontmatter.drop(forged, ["promoted_by", "anchors"])

      assert dropped == """
             ---
             name: x
             metadata:
               type: project
             description: kept
             ---
             Body
             """
    end

    test "leaves a file without frontmatter alone" do
      assert Frontmatter.drop("Body\n", ["anchors"]) == "Body\n"
    end
  end
end
