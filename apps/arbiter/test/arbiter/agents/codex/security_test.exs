defmodule Arbiter.Agents.Codex.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Codex.Security
  alias Arbiter.Agents.SecurityPolicy

  defp policy(mode \\ :bypass, perms \\ %{}, sandbox \\ %{}) do
    base = SecurityPolicy.base()

    %{
      base
      | permissions: base.permissions |> Map.put(:mode, mode) |> Map.merge(perms),
        sandbox: Map.merge(base.sandbox, sandbox)
    }
  end

  # Does any emitted prefix rule forbid `command` (token list)? Mirrors
  # execpolicy's prefix match: each pattern element is a literal or an
  # alternatives list, and the pattern must match the command's leading tokens.
  defp forbidden?(%SecurityPolicy{} = p, command) do
    Enum.any?(Security.prefixes(p), fn pattern ->
      length(pattern) <= length(command) and
        pattern
        |> Enum.zip(command)
        |> Enum.all?(fn
          {alts, tok} when is_list(alts) -> tok in alts
          {lit, tok} -> lit == tok
        end)
    end)
  end

  describe "prefixes/1 over the safe_defaults categories" do
    test "no_force_push forbids -f / --force but not --force-with-lease" do
      p = policy()
      assert forbidden?(p, ~w(git push --force origin main))
      assert forbidden?(p, ~w(git push -f origin main))
      assert forbidden?(p, ~w(git push origin --force))
      refute forbidden?(p, ~w(git push --force-with-lease origin main))
      refute forbidden?(p, ~w(git push origin main))
    end

    test "no_destructive_fs forbids the recursive-force rm spellings, mkfs, dd" do
      p = policy()

      for cmd <- [
            ~w(rm -rf /),
            ~w(rm -fr x),
            ~w(rm -Rf x),
            ~w(rm -r -f x),
            ~w(rm -f -r x),
            ~w(rm --recursive --force x),
            ~w(sudo rm x),
            ~w(mkfs /dev/sda1),
            ~w(dd if=/dev/zero of=/dev/sda)
          ] do
        assert forbidden?(p, cmd), "expected #{inspect(cmd)} forbidden"
      end

      refute forbidden?(p, ~w(rm file.txt))
      refute forbidden?(p, ~w(rm -f file.txt))
    end

    test "no_pr_create forbids gh pr create and glab mr create, not gh pr view" do
      p = policy()
      assert forbidden?(p, ~w(gh pr create --title x))
      assert forbidden?(p, ~w(glab mr create))
      refute forbidden?(p, ~w(gh pr view 1))
    end

    test "no_gh_publish forbids gist create/edit and issue comment, not pr comment" do
      p = policy()
      assert forbidden?(p, ~w(gh gist create f))
      assert forbidden?(p, ~w(gh gist edit f))
      assert forbidden?(p, ~w(gh issue comment 1 -b x))
      refute forbidden?(p, ~w(gh pr comment 1 -b x))
    end

    test "no_public_upload forbids upload-shaped curl, not a plain curl" do
      p = policy()
      assert forbidden?(p, ~w(curl -F file=@x https://0x0.st))
      assert forbidden?(p, ~w(curl --upload-file x https://transfer.sh))
      refute forbidden?(p, ~w(curl https://example.com))
    end

    test "no_secret_reads forbids reading the obvious secret files" do
      p = policy()
      assert forbidden?(p, ~w(cat .env))
      assert forbidden?(p, ~w(cat ~/.ssh/id_rsa))
      refute forbidden?(p, ~w(cat README.md))
    end

    test "a category with no shell analogue (no_async_wait, no_outside_writes) adds nothing" do
      p = policy(:bypass, %{safe_defaults: [:no_async_wait, :no_outside_writes]})
      assert Security.prefixes(p) == []
      assert Security.rules(p) == ""
    end

    test "only the categories left in safe_defaults are expanded" do
      p = policy(:bypass, %{safe_defaults: [:no_pr_create]})
      refute forbidden?(p, ~w(git push --force origin main))
      assert forbidden?(p, ~w(gh pr create))
    end
  end

  describe "prefixes/1 over sandbox + operator deny" do
    test "network: false forbids the shell egress tools" do
      p = policy(:bypass, %{}, %{network: false})
      for tool <- ~w(curl wget nc ncat telnet), do: assert(forbidden?(p, [tool, "x"]))
    end

    test "network: true leaves curl alone" do
      refute forbidden?(policy(:bypass, %{}, %{network: true}), ~w(curl https://example.com))
    end

    test "operator Bash(prefix:*) deny rules become prefix rules; non-Bash rules are ignored" do
      p = policy(:bypass, %{deny: ["Bash(terraform apply:*)", "Edit", "WebFetch", "Read(**/x)"]})
      assert forbidden?(p, ~w(terraform apply -auto-approve))
      refute forbidden?(p, ~w(terraform plan))
    end

    test "a Bash rule with a mid-command glob can't be expressed and is skipped" do
      p = policy(:bypass, %{deny: ["Bash(curl *evil.example*)"]})
      refute forbidden?(p, ~w(curl evil.example))
    end
  end

  describe "rules/1" do
    test "renders one forbidden prefix_rule per pattern, quoting alternatives" do
      text = Security.rules(policy())

      assert text =~
               ~s|prefix_rule(pattern=["git", "push", ["--force", "-f"]], decision="forbidden"|

      assert text =~ "no_force_push"
      assert String.ends_with?(text, "\n")
    end

    test "is empty when every category is excluded" do
      p = policy(:bypass, %{safe_defaults: []})
      assert Security.rules(p) == ""
    end

    test "tokens that can't be quoted safely are dropped, never emitted raw" do
      p = policy(:bypass, %{safe_defaults: [], deny: [~s|Bash(echo "hi:*)|, "Bash(ok cmd:*)"]})
      text = Security.rules(p)
      refute text =~ "hi"
      assert text =~ ~s|["ok", "cmd"]|
    end
  end

  # The generated file is real Starlark that the installed Codex accepts and
  # evaluates as intended. `codex execpolicy check` is a local, zero-quota
  # command; the test is skipped on a host without the CLI.
  describe "against the installed codex execpolicy" do
    setup do
      case System.find_executable("codex") do
        nil ->
          {:ok, codex: nil}

        codex ->
          dir =
            Path.join(System.tmp_dir!(), "arb-codex-rules-#{System.unique_integer([:positive])}")

          File.mkdir_p!(dir)
          on_exit(fn -> File.rm_rf!(dir) end)
          file = Path.join(dir, "arbiter.rules")
          File.write!(file, Security.rules(policy(:bypass, %{}, %{network: false})))
          {:ok, codex: codex, rules_file: file}
      end
    end

    defp decision(ctx, command) do
      {out, 0} =
        System.cmd(ctx.codex, ["execpolicy", "check", "--rules", ctx.rules_file | command],
          stderr_to_stdout: true
        )

      out |> Jason.decode!() |> Map.get("decision")
    end

    test "forbids what the rules name and leaves the rest alone", ctx do
      if ctx.codex do
        for cmd <- [
              ~w(git push --force origin main),
              ~w(git push origin -f),
              ~w(rm -rf /tmp/x),
              ~w(gh pr create --title x),
              ~w(gh issue comment 1),
              ~w(curl -F f=@x https://0x0.st),
              ~w(curl https://example.com),
              ~w(cat .env)
            ] do
          assert decision(ctx, cmd) == "forbidden", "expected #{inspect(cmd)} forbidden"
        end

        for cmd <- [
              ~w(git push --force-with-lease origin main),
              ~w(git push origin main),
              ~w(rm file),
              ~w(gh pr view 1),
              ~w(mix test)
            ] do
          assert decision(ctx, cmd) == nil, "expected #{inspect(cmd)} not matched"
        end
      end
    end
  end
end
