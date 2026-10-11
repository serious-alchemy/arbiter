defmodule Arbiter.Agents.Qwen.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Qwen.Security
  alias Arbiter.Agents.SecurityPolicy

  @home "/home/operator"

  defp policy(perms, sandbox \\ %{}) do
    base = SecurityPolicy.base()

    %{
      base
      | permissions: Map.merge(base.permissions, perms),
        sandbox: Map.merge(base.sandbox, sandbox)
    }
  end

  defp only(category, extra \\ %{}) do
    policy(Map.merge(%{safe_defaults: [category], deny: []}, extra))
  end

  defp rules(p, opts \\ []), do: Security.deny_rules(p, Keyword.put_new(opts, :home, @home))

  describe "deny_rules/2 per safe_defaults category" do
    test ":no_destructive_fs denies the recursive-force rm spellings, mkfs and dd" do
      denied = rules(only(:no_destructive_fs))

      for rule <- [
            "Bash(rm -rf *)",
            "Bash(rm -fr *)",
            "Bash(rm -r -f *)",
            "Bash(rm --recursive --force *)",
            "Bash(sudo rm *)",
            "Bash(mkfs *)",
            "Bash(dd *)"
          ] do
        assert rule in denied, "missing #{rule}"
      end
    end

    test ":no_force_push denies --force and -f but not --force-with-lease" do
      denied = rules(only(:no_force_push))

      assert "Bash(git push --force *)" in denied
      assert "Bash(git push -f *)" in denied
      refute Enum.any?(denied, &(&1 =~ "force-with-lease"))
    end

    test ":no_secret_reads denies Read on the secret globs" do
      denied = rules(only(:no_secret_reads))

      for glob <- ~w(**/.env **/.env.* **/*.pem **/id_rsa **/id_ed25519 **/.ssh/** **/.netrc) do
        assert "Read(#{glob})" in denied, "missing Read(#{glob})"
      end
    end

    test ":no_outside_writes denies Edit under system and credential dirs, in every spelling" do
      denied = rules(only(:no_outside_writes), qwen_home: "/var/w/h/.qwen")

      for path <- ["/etc/**", "/usr/**", "~/.ssh/**", "#{@home}/.ssh/**", "#{@home}/.qwen/**"] do
        assert "Edit(#{path})" in denied, "missing Edit(#{path})"
      end

      assert "Edit(/var/w/h/.qwen/**)" in denied
    end

    test ":no_pr_create, :no_gh_publish and :no_ci_watch deny the gh / glab commands" do
      assert "Bash(gh pr create *)" in rules(only(:no_pr_create))
      assert "Bash(glab mr create *)" in rules(only(:no_pr_create))
      assert "Bash(gh gist create *)" in rules(only(:no_gh_publish))
      assert "Bash(gh issue comment *)" in rules(only(:no_gh_publish))
      assert "Bash(gh run watch *)" in rules(only(:no_ci_watch))
      assert "Bash(gh pr checks *)" in rules(only(:no_ci_watch))
    end

    test ":no_public_upload denies WebFetch and curl-style uploads to the paste hosts" do
      denied = rules(only(:no_public_upload))

      assert "WebFetch(domain:catbox.moe)" in denied
      assert "Bash(curl *catbox.moe*)" in denied
    end
  end

  describe "tool removal" do
    test "network: false removes web_fetch / web_search and denies the network commands" do
      p = policy(%{safe_defaults: [], deny: []}, %{network: false})

      assert Security.exclude_tools(p) == ["web_fetch", "web_search"]
      assert "WebFetch" in rules(p)
      assert "Bash(curl *)" in rules(p)
    end

    test "operator Write / Edit / Bash denies remove the matching tools" do
      p = policy(%{safe_defaults: [], deny: ["Edit", "Write"]})
      assert Enum.sort(Security.exclude_tools(p)) == ["edit", "write_file"]

      p = policy(%{safe_defaults: [], deny: ["Bash"]})
      assert Security.exclude_tools(p) == ["run_shell_command"]

      p = policy(%{safe_defaults: [], deny: ["Agent"]})
      assert Security.exclude_tools(p) == ["task"]
    end

    test "a reviewer policy (Write denied) loses every write tool" do
      p = policy(%{safe_defaults: [], deny: ["Edit", "Write", "NotebookEdit"]})
      assert Security.exclude_tools(p) |> Enum.sort() == ["edit", "write_file"]
    end

    test "no deny and network on removes nothing" do
      assert Security.exclude_tools(policy(%{safe_defaults: [], deny: []})) == []
    end
  end

  describe "operator deny entries" do
    test "a rule in Claude's grammar passes through" do
      assert "Bash(ls *)" in rules(policy(%{safe_defaults: [], deny: ["Bash(ls *)"]}))
    end

    test "Claude's legacy :* prefix spelling is rewritten to qwen's space-star" do
      assert "Bash(git push:*)" not in rules(
               policy(%{safe_defaults: [], deny: ["Bash(git push:*)"]})
             )

      assert "Bash(git push *)" in rules(policy(%{safe_defaults: [], deny: ["Bash(git push:*)"]}))
    end

    test "entries with no qwen spelling are dropped and reported, never passed through" do
      p = policy(%{safe_defaults: [], deny: ["Foo(x)", "NotebookEdit", "Edit"]})

      assert Security.unmapped(p) == ["Foo(x)"]
      refute "Foo(x)" in rules(p)
    end
  end

  describe "coverage guard" do
    test "every safe_defaults category has a recorded mapping (deny rules, tool removal or the jail)" do
      for category <- SecurityPolicy.safe_default_categories() do
        assert [_ | _] = mapping = Security.coverage()[category],
               "#{category} has no qwen mapping"

        assert Enum.all?(mapping, &(&1 in [:deny, :tools, :jail]))
      end
    end

    test "a category recorded as :deny or :tools actually produces rules or removed tools" do
      for {category, layers} <- Security.coverage(),
          layer <- layers,
          layer in [:deny, :tools] do
        p = only(category)

        produced =
          case layer do
            :deny -> rules(p, qwen_home: "/x/.qwen")
            :tools -> Security.exclude_tools(p)
          end

        assert produced != [], "#{category} claims #{layer} but emits nothing"
      end
    end

    test ":no_async_wait has no qwen tool to remove and is carried by the jail" do
      assert Security.coverage()[:no_async_wait] == [:jail]
      assert Security.exclude_tools(only(:no_async_wait)) == []
    end

    test "the default policy emits a deduped, non-empty rule list" do
      denied = rules(SecurityPolicy.default())
      assert denied != []
      assert denied == Enum.uniq(denied)
    end
  end

  describe "settings/2" do
    test "is the permissions.deny / tools.exclude fragment of the system settings" do
      p = policy(%{safe_defaults: [:no_pr_create], deny: ["Edit"]})
      settings = Security.settings(p, home: @home)

      assert "Bash(gh pr create *)" in settings["permissions"]["deny"]
      assert settings["tools"]["exclude"] == ["edit"]
    end

    test "omits tools.exclude when nothing is removed" do
      settings = Security.settings(only(:no_pr_create), home: @home)
      refute Map.has_key?(settings, "tools")
    end
  end
end
