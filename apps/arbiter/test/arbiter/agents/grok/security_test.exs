defmodule Arbiter.Agents.Grok.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Grok.Security
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

  # A policy that denies exactly one category, so the argv is that category's.
  defp only(category, extra \\ %{}) do
    policy(Map.merge(%{safe_defaults: [category], deny: []}, extra))
  end

  defp rules(p, opts \\ []), do: Security.deny_rules(p, Keyword.put_new(opts, :home, @home))

  defp flag_values(argv, flag) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(&(hd(&1) == flag))
    |> Enum.map(&List.last/1)
  end

  describe "argv/2 per safe_defaults category" do
    test ":no_destructive_fs denies the rm / mkfs / dd spellings" do
      argv = Security.argv(only(:no_destructive_fs), home: @home)

      for rule <- [
            "Bash(rm -rf:*)",
            "Bash(rm -fr:*)",
            "Bash(rm -r -f:*)",
            "Bash(rm -f -r:*)",
            "Bash(rm -Rf:*)",
            "Bash(rm --recursive --force:*)",
            "Bash(sudo rm:*)",
            "Bash(mkfs:*)",
            "Bash(dd:*)"
          ] do
        assert rule in flag_values(argv, "--deny"), "missing #{rule}"
      end
    end

    test ":no_force_push denies --force / -f but not --force-with-lease" do
      denied = flag_values(Security.argv(only(:no_force_push), home: @home), "--deny")

      assert "Bash(git push --force:*)" in denied
      assert "Bash(git push -f:*)" in denied
      assert "Bash(git push --force=:*)" in denied
      refute Enum.any?(denied, &(&1 =~ "force-with-lease"))
    end

    test ":no_secret_reads denies Read on the secret globs (shell reads share the rule)" do
      denied = flag_values(Security.argv(only(:no_secret_reads), home: @home), "--deny")

      for glob <-
            ~w(**/.env **/.env.* **/*.pem **/id_rsa **/id_ed25519 **/.ssh/** **/.aws/credentials **/.netrc **/.npmrc **/secrets/**) do
        assert "Read(#{glob})" in denied, "missing Read(#{glob})"
      end
    end

    test ":no_outside_writes denies Edit under system and credential dirs, in every spelling" do
      denied = flag_values(Security.argv(only(:no_outside_writes), home: @home), "--deny")

      for path <- ["/etc/**", "/usr/**"] do
        assert "Edit(#{path})" in denied
      end

      # grok matches a `~`-prefixed tool path literally and never expands a
      # pattern's `~/`, so both the literal and the absolute spelling are needed.
      for dir <- ~w(.ssh .claude .config .grok) do
        assert "Edit(~/#{dir}/**)" in denied, "missing literal ~/#{dir}"
        assert "Edit(#{@home}/#{dir}/**)" in denied, "missing absolute #{dir}"
      end
    end

    test ":no_outside_writes also denies the spawn's own GROK_HOME when given" do
      denied =
        Security.argv(only(:no_outside_writes), home: @home, grok_home: "/w/home/.grok")
        |> flag_values("--deny")

      assert "Edit(/w/home/.grok/**)" in denied
    end

    test ":no_pr_create denies gh pr create and glab mr create" do
      denied = flag_values(Security.argv(only(:no_pr_create), home: @home), "--deny")
      assert "Bash(gh pr create:*)" in denied
      assert "Bash(glab mr create:*)" in denied
    end

    test ":no_gh_publish denies gist create/edit and issue comment" do
      denied = flag_values(Security.argv(only(:no_gh_publish), home: @home), "--deny")
      assert "Bash(gh gist create:*)" in denied
      assert "Bash(gh gist edit:*)" in denied
      assert "Bash(gh issue comment:*)" in denied
    end

    test ":no_public_upload denies WebFetch on each host and the upload tools naming it" do
      denied = flag_values(Security.argv(only(:no_public_upload), home: @home), "--deny")

      for host <- SecurityPolicy.public_upload_hosts() do
        assert "WebFetch(domain:#{host})" in denied
        assert "Bash(curl *#{host}*)" in denied
        assert "Bash(wget *#{host}*)" in denied
      end

      # grok's `domain:` pattern covers subdomains itself and takes no wildcard.
      refute Enum.any?(denied, &String.contains?(&1, "domain:*."))
    end

    test ":no_async_wait removes grok's monitor and scheduler tools" do
      argv = Security.argv(only(:no_async_wait), home: @home)
      [tools] = flag_values(argv, "--disallowed-tools")

      for tool <- ~w(monitor scheduler_create scheduler_list scheduler_delete) do
        assert tool in String.split(tools, ",")
      end
    end
  end

  describe "argv/2 sandbox network" do
    test "network: false removes the web tools and denies the network clients" do
      argv = Security.argv(policy(%{safe_defaults: [], deny: []}, %{network: false}), home: @home)
      denied = flag_values(argv, "--deny")

      assert "--disable-web-search" in argv
      assert "WebFetch" in denied
      assert "WebSearch" in denied

      for tool <- ~w(curl wget nc ncat telnet) do
        assert "Bash(#{tool}:*)" in denied
      end
    end

    test "network: true leaves the web tools alone" do
      argv = Security.argv(policy(%{safe_defaults: [], deny: []}, %{network: true}), home: @home)
      refute "--disable-web-search" in argv
      refute "WebFetch" in flag_values(argv, "--deny")
    end
  end

  describe "argv/2 operator deny entries" do
    test "tool-scoped rules in grok's grammar pass through" do
      p = only(:no_async_wait, %{deny: ["Bash(rm -rf /tmp/x:*)", "Read(**/*.key)", "mcp__x__y"]})
      denied = flag_values(Security.argv(p, home: @home), "--deny")

      assert "Bash(rm -rf /tmp/x:*)" in denied
      assert "Read(**/*.key)" in denied
      assert "mcp__x__y" in denied
    end

    test "a review dispatch's Edit / Write / NotebookEdit deny removes the write tools" do
      p = only(:no_async_wait, %{deny: ["Edit", "Write", "NotebookEdit"]})
      argv = Security.argv(p, home: @home)
      denied = flag_values(argv, "--deny")
      tools = argv |> flag_values("--disallowed-tools") |> Enum.flat_map(&String.split(&1, ","))

      assert "Edit" in denied
      assert "Write" in denied
      assert "write" in tools
      assert "search_replace" in tools
      # grok rejects `--deny NotebookEdit` ("unsupported tool prefix") and aborts.
      refute "NotebookEdit" in denied
    end

    test "a bare Bash deny removes the shell tool; WebFetch/WebSearch turn web search off" do
      argv = Security.argv(only(:no_async_wait, %{deny: ["Bash", "WebSearch"]}), home: @home)
      tools = argv |> flag_values("--disallowed-tools") |> Enum.flat_map(&String.split(&1, ","))

      assert "run_terminal_command" in tools
      assert "run_terminal_cmd" in tools
      assert "--disable-web-search" in argv
    end

    test "an Agent or Task deny becomes --no-subagents" do
      for entry <- ["Agent", "Task"] do
        argv = Security.argv(only(:no_async_wait, %{deny: [entry]}), home: @home)
        assert "--no-subagents" in argv
        refute entry in flag_values(argv, "--deny")
      end

      refute "--no-subagents" in Security.argv(only(:no_async_wait), home: @home)
    end

    test "entries grok would abort on or cannot express are dropped, not emitted" do
      p = only(:no_async_wait, %{deny: ["Foo(bar)", "Agent(model:opus)", "Bash(", "", "Edit\n"]})
      argv = Security.argv(p, home: @home)
      denied = flag_values(argv, "--deny")

      for bad <- ["Foo(bar)", "Agent(model:opus)", "Bash(", "", "Edit\n"] do
        refute bad in denied
      end

      assert Enum.sort(Security.unmapped(p)) ==
               Enum.sort(["Foo(bar)", "Agent(model:opus)", "Bash(", "", "Edit\n"])
    end
  end

  describe "coverage guard" do
    test "every safe_defaults category produces a grok flag, so a new category cannot ship unmapped" do
      for category <- SecurityPolicy.safe_default_categories() do
        argv = Security.argv(only(category), home: @home)
        assert argv != [], "#{category} has no grok mapping"
      end
    end

    test "the default policy's argv is deduped, non-empty and made of known flags" do
      argv = Security.argv(SecurityPolicy.default(), home: @home)
      denied = flag_values(argv, "--deny")

      assert denied != []
      assert denied == Enum.uniq(denied)

      flags = Enum.filter(argv, &String.starts_with?(&1, "--"))

      assert Enum.all?(
               flags,
               &(&1 in ~w(--deny --disallowed-tools --disable-web-search --no-subagents))
             )
    end

    test "a session policy's mint-token deny reaches grok as a Bash rule" do
      assert "Bash(arb mcp token mint:*)" in rules(SecurityPolicy.interactive_session_base())
    end

    test "every emitted rule is a recognised tool prefix (grok aborts the spawn on others)" do
      p = policy(%{deny: ["Foo(x)", "NotebookEdit", "Edit", "Bash(ls:*)"]}, %{network: false})

      for rule <- rules(p) do
        assert rule =~
                 ~r/\A(Bash|Read|Edit|Write|Grep|Glob|MCPTool|WebFetch|WebSearch|mcp__[\w*]+)(\(|\z)/,
               "unrecognised prefix: #{rule}"
      end
    end
  end
end
