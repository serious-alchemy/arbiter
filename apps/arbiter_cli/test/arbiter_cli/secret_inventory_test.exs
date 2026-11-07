defmodule ArbiterCli.SecretInventoryTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.SecretInventory

  defp state(entries, name), do: Enum.find(entries, &(&1.name == name))

  describe "classify/1" do
    test "separates inline values, references, shadowed values and unset names" do
      env = %{
        "ARBITER_CLOAK_KEY_REF" => "aws-sm:prod/arbiter#cloak",
        "SECRET_KEY_BASE" => "inline-skb",
        "GITHUB_TOKEN" => "ghp_inline",
        "GITHUB_TOKEN_REF" => "aws-ssm:/arbiter/gh",
        "GEMINI_API_KEY_REF" => "file:/run/credentials/gemini",
        "ANTHROPIC_API_KEY" => "  "
      }

      entries = SecretInventory.classify(env)

      assert %{state: :ref, scheme: "aws-sm"} = state(entries, "ARBITER_CLOAK_KEY")
      assert %{state: :inline, scheme: nil} = state(entries, "SECRET_KEY_BASE")
      assert %{state: :shadowed, scheme: "aws-ssm"} = state(entries, "GITHUB_TOKEN")
      assert %{state: :ref, scheme: "file"} = state(entries, "GEMINI_API_KEY")
      assert %{state: :unset} = state(entries, "ANTHROPIC_API_KEY")
    end

    test "an unrecognised pointer is reported as invalid" do
      entries = SecretInventory.classify(%{"SECRET_KEY_BASE_REF" => "just-a-literal"})
      assert %{state: :ref, scheme: "invalid"} = state(entries, "SECRET_KEY_BASE")
    end
  end

  test "inline_boot_secrets/1 names only the boot secrets still inline" do
    entries =
      SecretInventory.classify(%{
        "ARBITER_CLOAK_KEY" => "k",
        "SECRET_KEY_BASE_REF" => "aws-sm:x",
        "GITHUB_TOKEN" => "t"
      })

    assert SecretInventory.inline_boot_secrets(entries) == ["ARBITER_CLOAK_KEY"]
  end

  test "summary/1 never contains a value" do
    entries =
      SecretInventory.classify(%{
        "SECRET_KEY_BASE" => "hunter2hunter2",
        "GITHUB_TOKEN_REF" => "file:/x"
      })

    summary = SecretInventory.summary(entries)
    refute summary =~ "hunter2"
    assert summary =~ "inline: SECRET_KEY_BASE"
    assert summary =~ "GITHUB_TOKEN (file)"
  end

  test "fingerprint/1 is key names plus an 8-char hash prefix, sorted" do
    [a, b] = SecretInventory.fingerprint(%{"B" => "two", "A" => "one"})
    assert a.key == "A" and b.key == "B"
    assert String.length(a.sha256) == 8
    assert a.sha256 != b.sha256
    refute inspect([a, b]) =~ "one"
  end

  @tag :tmp_dir
  test "env_from_file/1 parses KEY=VALUE lines, quotes and export", %{tmp_dir: dir} do
    path = Path.join(dir, "arbiter.env")
    File.write!(path, "# c\nexport A=\"x y\"\nB='z'\nC=plain\nnot a line\n")
    assert SecretInventory.env_from_file(path) == %{"A" => "x y", "B" => "z", "C" => "plain"}
    assert SecretInventory.env_from_file(Path.join(dir, "missing")) == %{}
  end
end
