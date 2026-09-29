defmodule Arbiter.Agents.Gemini.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy

  defp policy(overrides \\ %{}), do: SecurityPolicy.merge(SecurityPolicy.base(), overrides)

  defp mode(m), do: policy(%{"permissions" => %{"mode" => m}})

  defp review_policy do
    Arbiter.Worker.Dispatch.review_security_policy(
      SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}}),
      review_checkout: %{path: "/tmp/some-review-checkout"}
    )
  end

  describe "permission_argv/1" do
    test "bypass -> --dangerously-skip-permissions" do
      assert Security.permission_argv(mode("bypass")) == ["--dangerously-skip-permissions"]
    end

    test "auto -> no flag (the generated settings carry the posture)" do
      assert Security.permission_argv(mode("auto")) == []
    end

    test "strict -> no flag (bd-25ivqe: --sandbox drops the allowlist gate, see moduledoc)" do
      assert Security.permission_argv(mode("strict")) == []
    end
  end

  describe "tool_permission/1 — the agy `toolPermission` value" do
    test "strict never resolves to always-proceed (bd-7s29yq AC1)" do
      refute Security.tool_permission(mode("strict")) == "always-proceed"
    end

    test "strict resolves to proceed-in-sandbox, not agy's own `strict` value (bd-25ivqe)" do
      # agy's `toolPermission: "strict"` auto-denies every tool call in headless
      # mode regardless of `permissions.allow` content — confirmed live against
      # the installed agy 1.2.8: a bare `command(arb)`, a wildcard `command(*)`,
      # and even the literal full command string all still came back
      # `permission check failed for unsandboxed ...` under `"strict"`.
      # `"proceed-in-sandbox"` is the value that actually consults
      # `permissions.allow` headlessly (confirmed live the same way: the exact
      # same settings document, only `toolPermission` changed, let an
      # allow-listed command through and denied a non-allow-listed one).
      assert Security.tool_permission(mode("strict")) == "proceed-in-sandbox"
    end

    test "auto and bypass are always-proceed — headless cannot answer a prompt" do
      assert Security.tool_permission(mode("auto")) == "always-proceed"
      assert Security.tool_permission(mode("bypass")) == "always-proceed"
    end
  end

  describe "settings/2" do
    test "the default (bypass) policy generates a non-empty deny list" do
      settings = Security.settings(policy())

      assert settings["toolPermission"] == "always-proceed"
      assert settings["allowNonWorkspaceAccess"] == false
      assert is_list(settings["permissions"]["deny"])
      assert settings["permissions"]["deny"] != []
    end

    test "strict mode reports toolPermission proceed-in-sandbox, not the inherited always-proceed" do
      settings = Security.settings(mode("strict"))

      assert settings["toolPermission"] == "proceed-in-sandbox"
      assert settings["permissions"]["deny"] != []
    end

    test "deny rules are emitted in agy's own grammar, never Claude's" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "command(rm -rf)" in deny
      assert "command(git push --force)" in deny
      assert "command(gh pr create)" in deny
      # No Claude-flavoured rule survives the translation.
      refute Enum.any?(deny, &String.starts_with?(&1, "Bash("))
      refute Enum.any?(deny, &String.starts_with?(&1, "Read("))
    end

    test "secret-read denies become read_file rules" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "read_file(**/.env)" in deny
      assert "read_file(**/.ssh/**)" in deny
    end

    test "outside-write denies become write_file rules" do
      deny = Security.settings(policy())["permissions"]["deny"]

      assert "write_file(/etc)" in deny
    end

    test "operator allow rules are translated too" do
      p = policy(%{"permissions" => %{"mode" => "strict", "allow" => ["Bash(mix test:*)"]}})

      assert "command(mix test)" in Security.settings(p)["permissions"]["allow"]
    end

    test "strict allows the arbiter MCP server only (bd-cy4ls6)" do
      allow = Security.settings(mode("strict"))["permissions"]["allow"]

      assert "mcp(arbiter/*)" in allow
      assert Enum.filter(allow, &String.starts_with?(&1, "mcp(")) == ["mcp(arbiter/*)"]
    end

    test "non-strict modes add no mcp allow rule (bd-cy4ls6)" do
      allow = Security.settings(mode("bypass"))["permissions"]["allow"] || []
      refute Enum.any?(allow, &String.starts_with?(&1, "mcp("))
    end

    test "strict mode always allows the worker-protocol bootstrap commands (bd-25ivqe AC1)" do
      settings = Security.settings(mode("strict"))
      allow = settings["permissions"]["allow"]
      deny = settings["permissions"]["deny"]

      assert "command(arb)" in allow
      assert "command(git status)" in allow
      assert "command(git diff)" in allow
      assert "command(git log)" in allow

      # With no worktree in hand the only write allow is the jail's private
      # `/tmp` (bd-f8f9ln), and `/etc` stays denied under :strict the same
      # way it does under :bypass.
      assert "write_file(/etc)" in deny
      assert Enum.filter(allow, &String.starts_with?(&1, "write_file(")) == ["write_file(/tmp)"]
    end

    test "the bootstrap baseline is present alongside operator allow rules, not replaced by them" do
      p = policy(%{"permissions" => %{"mode" => "strict", "allow" => ["Bash(mix test:*)"]}})
      allow = Security.settings(p)["permissions"]["allow"]

      assert "command(arb)" in allow
      assert "command(mix test)" in allow
    end

    test "the bootstrap baseline also applies to a worktree-backed review-agent policy" do
      review =
        Arbiter.Worker.Dispatch.review_security_policy(
          SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}}),
          review_checkout: %{path: "/tmp/some-review-checkout"}
        )

      allow = Security.allow_rules(review)
      assert "command(arb)" in allow
      assert "command(git status)" in allow
    end

    test "an operator deny still wins over the bootstrap allow baseline (AC2)" do
      p =
        policy(%{
          "permissions" => %{"mode" => "strict", "deny" => ["Bash(arb:*)"]}
        })

      settings = Security.settings(p)
      assert "command(arb)" in settings["permissions"]["allow"]
      assert "command(arb)" in settings["permissions"]["deny"]
    end

    # bd-80talz: agy's URL rule kinds are `read_url(<domain>)` and
    # `execute_url(<domain>)`. Probed on agy 1.2.11: agy rewrites settings.json
    # on load and silently DROPS a `url(*)` rule, so the old network-off deny
    # never reached the tool. `read_url(*)` survives the rewrite and blocks.
    test "a policy with network: false denies read_url(*) as well as the curl/wget commands" do
      p = policy(%{"sandbox" => %{"network" => false}})
      deny = Security.settings(p)["permissions"]["deny"]

      assert "read_url(*)" in deny
      assert "execute_url(*)" in deny
      assert "command(curl)" in deny
      refute "url(*)" in deny
    end

    test "network: true leaves read_url(*) alone" do
      refute "read_url(*)" in Security.settings(policy())["permissions"]["deny"]
    end

    test "a known worktree is trusted so agy never gates on folder trust" do
      settings = Security.settings(policy(), worktree: "/tmp/wt")
      assert settings["trustedWorkspaces"] == ["/tmp/wt"]
    end

    test "no worktree in hand omits trustedWorkspaces entirely" do
      refute Map.has_key?(Security.settings(policy()), "trustedWorkspaces")
    end

    test "a worktree-backed review spawn's read-only deny survives translation" do
      # Arbiter.Worker.Dispatch.review_security_policy/2 merges these three bare
      # Claude tool names into EVERY worktree-backed review dispatch. They are
      # what makes "you are not the author; do not modify the branch" a property
      # of the spawn; if they are dropped an agy reviewer can rewrite the branch
      # it is reviewing while a Claude reviewer cannot.
      review =
        SecurityPolicy.merge(SecurityPolicy.base(), %{
          "permissions" => %{"deny" => ["Edit", "Write", "NotebookEdit"]}
        })

      assert "write_file(/)" in Security.deny_rules(review)
    end

    test "the exact policy Dispatch.review_security_policy/2 produces denies writes" do
      # Built through Dispatch itself, so a change to the reviewer posture that
      # agy cannot express fails here rather than silently.
      policy =
        Arbiter.Worker.Dispatch.review_security_policy(
          SecurityPolicy.base(),
          review_checkout: %{path: "/tmp/some-review-checkout"}
        )

      assert "write_file(/)" in Security.deny_rules(policy)
    end

    test "a review dispatch allows the read-only tracker commands (bd-cwe9n2)" do
      review = review_policy()
      allow = Security.allow_rules(review)

      for cmd <- [
            "gh pr view",
            "gh pr diff",
            "gh pr checks",
            "glab mr view",
            "glab mr diff",
            "glab ci status",
            "glab ci get"
          ] do
        assert "command(#{cmd})" in allow, "#{cmd} must be allowed on the review path"
      end

      refute "command(gh pr merge)" in allow
    end

    test "a review dispatch keeps tracker writes denied (bd-cwe9n2)" do
      deny = Security.deny_rules(review_policy())

      for cmd <-
            [
              "gh pr comment",
              "gh pr review",
              "gh pr merge",
              "gh pr close",
              "gh pr edit",
              "gh api -X",
              "gh api --method",
              "glab mr note",
              "glab mr comment",
              "glab mr approve",
              "glab mr merge",
              "glab mr close",
              "glab mr update",
              "glab api -X",
              "glab api --method"
            ] do
        assert "command(#{cmd})" in deny, "#{cmd} must be denied on the review path"
      end
    end

    test "a non-review policy gets neither the tracker allow nor the tracker deny" do
      p = SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}})

      refute "command(gh pr view)" in Security.allow_rules(p)
      refute "command(gh pr merge)" in Security.deny_rules(p)
    end

    test "bare Read / WebFetch tool names map onto agy's whole-path rules" do
      deny =
        Security.deny_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{
            "permissions" => %{"deny" => ["Read", "WebFetch"]}
          })
        )

      assert "read_file(/)" in deny
      assert "read_url(*)" in deny
      refute "url(*)" in deny
    end

    test "a bare tool name in `allow` translates too (load-bearing under :strict)" do
      allow =
        Security.allow_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{
            "permissions" => %{"mode" => "strict", "allow" => ["Read", "Edit"]}
          })
        )

      assert "read_file(/)" in allow
      assert "write_file(/)" in allow
    end

    test "`pwd` is allowed in every mode, so `pwd && git status` is not soft-denied (bd-7wymls)" do
      allow =
        Security.allow_rules(
          SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}})
        )

      assert "command(pwd)" in allow
      # Deliberately NOT a general read escape hatch.
      refute "command(cat)" in allow
      refute "command(ls)" in allow
    end

    test "rules with no agy analogue are dropped rather than emitted verbatim" do
      # Monitor / ScheduleWakeup are Claude tool names; agy's rule grammar has
      # only command()/read_file()/write_file()/url().
      deny = Security.settings(policy())["permissions"]["deny"]

      refute "Monitor" in deny
      refute "ScheduleWakeup" in deny
    end
  end

  describe "bootstrap_command?/1 — is a denied command one the worker protocol requires?" do
    test "the worker-protocol commands are required" do
      assert Security.bootstrap_command?("arb inbox bd-3a5qr2")
      assert Security.bootstrap_command?("arb")
      assert Security.bootstrap_command?("git status")
      assert Security.bootstrap_command?("git diff --stat main..HEAD")
      assert Security.bootstrap_command?("  git log --oneline -5")
    end

    test "anything else is not — including a chain that merely starts with an allowed command" do
      refute Security.bootstrap_command?("pwd && git status")
      refute Security.bootstrap_command?("echo probe > /tmp/x")
      refute Security.bootstrap_command?("git push origin main")
      refute Security.bootstrap_command?("arbiter-thing")
      refute Security.bootstrap_command?("git statusx")
      refute Security.bootstrap_command?("arb inbox && rm -rf .")
      refute Security.bootstrap_command?(nil)
      refute Security.bootstrap_command?("")
    end
  end

  describe "settings_json/2" do
    test "is pretty-printed, decodable JSON" do
      json = Security.settings_json(mode("strict"))
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["toolPermission"] == "proceed-in-sandbox"
    end
  end

  # bd-7s29yq / bd-25ivqe. All fixtures below are REAL events captured from
  # the installed `agy` (1.2.8), one line of
  # `agy -p ... --output-format stream-json`, against a `HOME` whose
  # `settings.json` is `Security.settings_json/2`'s own output verbatim:
  #
  #   * agy_init_strict.json          — the `init` event for a `:strict`
  #     policy, argv WITHOUT `--sandbox` (this ticket's fix).
  #   * agy_init_inherited.json       — the pre-fix posture: HOME carrying the
  #     operator's own `~/.gemini/antigravity-cli/settings.json`.
  #   * agy_run_command_allowed.json  — `run_command("arb --version")`
  #     against the bootstrap allow baseline: `state: "DONE"`, real output.
  #   * agy_run_command_denied.json   — `run_command("mix test")`, NOT on the
  #     allow list: `state: "ERROR"`, agy's real denial wording.
  #
  # `agy_init_inherited.json` is the control: it is what every agy worker
  # reported before bd-7s29yq, and it is why the first assertion below is not
  # vacuous. The `run_command` pair is what closes bd-25ivqe's post-merge
  # verification gap — the original fix asserted only on the *generated
  # settings document*, never on agy's actual matching behavior, and that
  # gap is exactly what let a non-functional `toolPermission: "strict"`
  # merge and fail live.
  describe "AC1 — captured agy `init` events" do
    test "a :strict spawn against our generated settings does not report always-proceed" do
      event = fixture("agy_init_strict.json")

      assert event["event"] == "init"
      refute event["init"]["permission_mode"] == "always-proceed"
      assert event["init"]["permission_mode"] == Security.tool_permission(mode("strict"))
    end

    test "the inherited-operator-settings control DOES report always-proceed" do
      assert fixture("agy_init_inherited.json")["init"]["permission_mode"] == "always-proceed"
    end

    defp fixture(name) do
      [__DIR__, "..", "..", "..", "fixtures", name]
      |> Path.join()
      |> Path.expand()
      |> File.read!()
      |> Jason.decode!()
    end
  end

  describe "AC6 (post-merge verification gap) — captured `run_command` matching against the generated allow list" do
    test "a bootstrap-allowed command (`arb`) actually runs, not just parses as allowed" do
      event = fixture("agy_run_command_allowed.json")
      step = event["step_update"]

      assert step["state"] == "DONE"
      assert step["tool_name"] == "run_command"
      assert step["tool_info"]["parameters"]["CommandLine"] == "arb --version"
      assert step["tool_info"]["output"] =~ "arb"
    end

    test "a command outside the allow list is auto-denied, not silently permitted" do
      event = fixture("agy_run_command_denied.json")
      step = event["step_update"]

      assert step["state"] == "ERROR"
      assert step["tool_info"]["error"]["message"] =~ "permission check failed"
    end
  end

  describe "AC6 (bd-25ivqe) — the old write_file(**) deny, re-read (bd-f8f9ln)" do
    test "the bd-7h2cuk capture wrote to /tmp, which agy lets through, under a glob that matches nothing" do
      # Captured live against agy 1.2.11 with `permissions.deny:
      # ["write_file(**)"]` and `toolPermission: "proceed-in-sandbox"`. It was
      # read as "write_file rules never gate write_to_file". bd-f8f9ln's probes
      # show two other reasons: a glob inside write_file(...) matches no path,
      # and agy auto-allows writes under /tmp. Both are pinned by
      # agy_write_file_rule_matching.json below.
      step = fixture("agy_write_to_file_deny_not_enforced.json")["step_update"]

      assert step["tool_name"] == "write_to_file"
      assert step["state"] == "DONE"
      assert step["tool_info"]["parameters"]["TargetFile"] =~ ~r{\A/tmp/}
    end
  end

  # bd-f8f9ln: real `write_to_file` step events captured from agy 1.2.11 under
  # `toolPermission: "proceed-in-sandbox"`, one per probe, each with the
  # settings.json permissions agy loaded and whether the file really appeared.
  describe "write_file rule matching on agy 1.2.11 (captured, bd-f8f9ln)" do
    setup do
      %{cases: fixture("agy_write_file_rule_matching.json")["cases"]}
    end

    test "an in-worktree write with no write_file allow is soft-denied (the bug)", %{cases: c} do
      probe = c["worktree_without_allow_soft_denied"]

      assert probe["result"]["denied_actions"] == [
               %{"action" => "write_file", "display_name" => "WriteToFile"}
             ]

      refute probe["file_created_on_disk"]
    end

    test "a `<dir>/**` allow matches nothing, a bare `<dir>` allow covers nested paths", %{
      cases: c
    } do
      glob = c["glob_allow_does_not_match"]
      assert Enum.any?(glob["settings_permissions"]["allow"], &String.ends_with?(&1, "/ws/**)"))
      assert glob["step_update"]["state"] == "ERROR"
      refute glob["file_created_on_disk"]

      dir = c["dir_allow_matches_nested"]
      assert Enum.any?(dir["settings_permissions"]["allow"], &String.ends_with?(&1, "/ws)"))
      assert dir["step_update"]["tool_info"]["parameters"]["TargetFile"] =~ "/ws/sub/a.txt"
      assert dir["step_update"]["state"] == "DONE"
      assert dir["file_created_on_disk"]
    end

    test "a worktree allow does not cover a path outside it, or a sibling sharing its prefix", %{
      cases: c
    } do
      for key <- ["outside_worktree_soft_denied", "sibling_prefix_soft_denied"] do
        probe = c[key]
        assert probe["step_update"]["state"] == "ERROR", key
        assert probe["result"]["denied_actions"] != nil, key
        refute probe["file_created_on_disk"], key
      end

      assert c["sibling_prefix_soft_denied"]["step_update"]["tool_info"]["parameters"][
               "TargetFile"
             ] =~ "/wsx/a.txt"
    end

    test "/tmp is auto-allowed with no rule, and an explicit write_file(/tmp) deny blocks it", %{
      cases: c
    } do
      assert c["tmp_auto_allowed"]["settings_permissions"] == %{"allow" => ["command(pwd)"]}
      assert c["tmp_auto_allowed"]["step_update"]["state"] == "DONE"

      denied = c["tmp_explicit_deny"]
      assert denied["step_update"]["state"] == "ERROR"

      assert denied["step_update"]["tool_info"]["error"]["message"] =~
               "Matches user-configured deny rule"
    end

    test "write_file(/) denies everything and outranks a worktree allow", %{cases: c} do
      probe = c["root_deny_beats_worktree_allow"]

      assert probe["settings_permissions"]["deny"] == ["write_file(/)"]
      assert probe["step_update"]["state"] == "ERROR"
      refute probe["file_created_on_disk"]
    end

    test "a write_file deny also holds under always-proceed and --dangerously-skip-permissions",
         %{cases: c} do
      for key <- ["always_proceed_root_deny", "skip_permissions_root_deny"] do
        probe = c[key]
        assert probe["toolPermission"] == "always-proceed", key
        assert probe["step_update"]["state"] == "ERROR", key

        assert probe["step_update"]["tool_info"]["error"]["message"] =~
                 "Matches user-configured deny rule",
               key

        refute probe["file_created_on_disk"], key
      end

      assert c["skip_permissions_root_deny"]["extra_argv"] == ["--dangerously-skip-permissions"]
    end
  end

  describe ":strict working set (bd-f8f9ln)" do
    @wt "/home/op/dev/worktrees/task-1"

    defp strict_allow(overrides \\ %{}, opts \\ [worktree: @wt]) do
      %{"permissions" => %{"mode" => "strict"}}
      |> deep_merge(overrides)
      |> policy()
      |> Security.settings(opts)
      |> get_in(["permissions", "allow"])
    end

    defp deep_merge(a, b),
      do: Map.merge(a, b, fn _k, x, y -> if is_map(x), do: deep_merge(x, y), else: y end)

    defp write_allows(allow), do: Enum.filter(allow, &String.starts_with?(&1, "write_file("))

    test "allows writes inside the worktree as a bare directory rule, never a glob" do
      allow = strict_allow()

      assert "write_file(#{@wt})" in allow
      refute Enum.any?(write_allows(allow), &(&1 =~ "*"))
    end

    test "allows the git/mix/arb commands a worker needs" do
      allow = strict_allow()

      for cmd <-
            ~w(arb mix) ++
              ["git status", "git diff", "git add", "git commit", "git rev-parse", "git push"] do
        assert "command(#{cmd})" in allow, cmd
      end
    end

    test "allows exactly the worktree, /tmp and sandbox.writable_paths for writes, nothing else" do
      home = System.user_home()

      allow =
        strict_allow(%{
          "sandbox" => %{"writable_paths" => ["~/.cache/shared-hex", "/opt/tool-cache"]}
        })

      assert Enum.sort(write_allows(allow)) ==
               Enum.sort([
                 "write_file(#{@wt})",
                 "write_file(/tmp)",
                 "write_file(#{Path.join(home, ".cache/shared-hex")})",
                 "write_file(/opt/tool-cache)"
               ])
    end

    test "still denies the outside paths, and write_file(/) for a review dispatch outranks the worktree allow" do
      review =
        Arbiter.Worker.Dispatch.review_security_policy(
          SecurityPolicy.merge(SecurityPolicy.base(), %{"permissions" => %{"mode" => "strict"}}),
          review_checkout: %{path: @wt}
        )

      settings = Security.settings(review, worktree: @wt)
      assert "write_file(#{@wt})" in settings["permissions"]["allow"]
      # agy checks deny before allow (captured: root_deny_beats_worktree_allow).
      assert "write_file(/)" in settings["permissions"]["deny"]
    end

    test "is only emitted under :strict; :auto/:bypass keep the bootstrap allow list" do
      for m <- ["auto", "bypass"] do
        allow = Security.settings(mode(m), worktree: @wt)["permissions"]["allow"]
        assert write_allows(allow) == [], m
        refute "command(mix)" in allow, m
      end
    end

    test "with no worktree in hand only /tmp is allowed for writes" do
      assert write_allows(strict_allow(%{}, [])) == ["write_file(/tmp)"]
    end
  end

  describe "write_file/read_file paths are emitted in the form agy matches (bd-f8f9ln)" do
    test "the outside-write baseline carries absolute directories, no globs and no `~`" do
      home = System.user_home()
      deny = Security.deny_rules(policy())

      for dir <- [
            "/etc",
            "/usr",
            "#{home}/.ssh",
            "#{home}/.gemini",
            "#{home}/.claude",
            "#{home}/.config"
          ] do
        assert "write_file(#{dir})" in deny, dir
      end

      refute Enum.any?(deny, &(String.starts_with?(&1, "write_file(") and &1 =~ ~r/[*~]/))
    end

    test "operator rules have a trailing glob stripped and `~` expanded" do
      home = System.user_home()

      deny =
        Security.deny_rules(
          policy(%{
            "permissions" => %{
              "deny" => [
                "Write(/srv/data/**)",
                "write_file(~/notes/*)",
                "Edit(**)",
                "Read(~/.aws)",
                "Write(/srv/logs*)"
              ]
            }
          })
        )

      assert "write_file(/srv/data)" in deny
      assert "write_file(#{home}/notes)" in deny
      assert "write_file(/)" in deny
      assert "read_file(#{home}/.aws)" in deny
      # Only a whole trailing `*`/`**` segment is stripped.
      assert "write_file(/srv/logs*)" in deny
    end

    test "a relative glob has no prefix form and is left untouched" do
      deny = Security.deny_rules(policy())

      assert "read_file(**/.env)" in deny
      assert "read_file(**/.ssh/**)" in deny
    end

    test "the isolated agy HOME's settings dir is denied when the home is known" do
      deny =
        Security.settings(policy(), worktree: "/w", home: "/cache/worker-agy/w-abc")[
          "permissions"
        ]["deny"]

      assert "write_file(/cache/worker-agy/w-abc/.gemini/antigravity-cli)" in deny
    end
  end

  describe "no_public_upload (bd-80talz)" do
    test "the resolved default policy denies read_url/execute_url for every documented host" do
      deny = Security.deny_rules(SecurityPolicy.resolve(nil))

      # Probed on agy 1.2.11: `read_url(catbox.moe)` blocked files.catbox.moe,
      # so a bare domain covers its subdomains (litter.catbox.moe too).
      for host <- SecurityPolicy.public_upload_hosts() do
        assert "read_url(#{host})" in deny
        assert "execute_url(#{host})" in deny
      end
    end

    test "denies gists and issue comments (no_gh_publish) and upload-shaped curl by prefix" do
      deny = Security.deny_rules(policy())

      assert "command(gh gist create)" in deny
      assert "command(gh gist edit)" in deny
      assert "command(gh issue comment)" in deny
      assert "command(curl -F)" in deny
      assert "command(curl --upload-file)" in deny
      refute Enum.any?(deny, &(&1 =~ "gh pr comment"))
    end

    test "never emits a glob inside command(...) — agy matches it literally, not as a pattern" do
      deny = Security.deny_rules(policy())
      refute Enum.any?(deny, &(String.starts_with?(&1, "command(") and &1 =~ "*"))
    end

    test "a Claude WebFetch domain rule translates to the same agy domain rule" do
      deny =
        Security.deny_rules(
          policy(%{"permissions" => %{"deny" => ["WebFetch(domain:example.com)"]}})
        )

      assert "read_url(example.com)" in deny
      refute "read_url(*)" in deny
    end

    test "an operator's legacy url(...) rule is rewritten to read_url(...)" do
      deny = Security.deny_rules(policy(%{"permissions" => %{"deny" => ["url(example.org)"]}}))

      assert "read_url(example.org)" in deny
      refute "url(example.org)" in deny
    end
  end
end
