defmodule Arbiter.Accounts.LoginTranscriptTest do
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.LoginTranscript

  @r LoginTranscript.placeholder()

  test "strips URL query strings and fragments but keeps host and path" do
    text = "visit https://claude.com/cai/oauth/authorize?code=true&state=S3CR3T#frag now\n"
    out = LoginTranscript.redact(text, nil, [])
    assert out == "visit https://claude.com/cai/oauth/authorize?#{@r} now\n"
    refute out =~ "S3CR3T"
  end

  test "unwraps OSC-8 hyperlinks before stripping, so the target's query cannot survive" do
    text = "\e]8;;https://x.test/a?state=LEAK\e\\label\e]8;;\e\\\n"
    refute LoginTranscript.redact(text, nil, []) =~ "LEAK"
  end

  test "blanks the recipe's device code, wherever the pattern finds it" do
    {:ok, recipe} = LoginRecipes.fetch(:codex)
    text = "Enter this one-time code (expires)\n   ABCD-12345\n"
    out = LoginTranscript.redact(text, recipe, [])
    assert out =~ @r
    refute out =~ "ABCD-12345"
  end

  test "blanks every secret, longest first, including echoed keystrokes" do
    out = LoginTranscript.redact("> abcdef-tail and abc\n", nil, ["abc", "abcdef-tail", nil, ""])
    assert out == "> #{@r} and #{@r}\n"
  end
end
