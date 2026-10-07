defmodule ArbiterCli.VerbsTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Verbs

  test "all/0 has unique names" do
    names = Enum.map(Verbs.all(), & &1.name)
    assert names == Enum.uniq(names)
  end

  test "every handler is loadable and exports run/1 (or is Main for help)" do
    for %{handler: h, name: n} <- Verbs.all() ++ Verbs.orphans(), h != ArbiterCli.Main do
      assert Code.ensure_loaded?(h), "#{n}: #{inspect(h)} not loadable"
      assert function_exported?(h, :run, 1), "#{n}: #{inspect(h)}.run/1 missing"
    end
  end

  test "aliases and legacy verbs are listed and flagged deprecated" do
    {:ok, issue} = Verbs.fetch("issue")
    assert issue.deprecated
    {:ok, list} = Verbs.fetch("list")
    assert list.kind == :legacy and list.deprecated
    assert Verbs.new_form(list) == "ticket list"
    {:ok, upgrade} = Verbs.fetch("upgrade")
    assert upgrade.handler == ArbiterCli.Cmd.SelfUpdate
  end

  test "every top-level cmd/*.ex handler module is reachable from the registry" do
    cmd_dir = Path.join([__DIR__, "..", "..", "lib", "arbiter_cli", "cmd"])
    files = Path.wildcard(Path.join(cmd_dir, "*.ex"))

    registered = MapSet.new(Enum.map(Verbs.all() ++ Verbs.orphans(), & &1.handler))
    sources = Map.new(files, &{&1, File.read!(&1)})

    # A module that is not itself a registered handler must be called from one
    # (the verb handlers delegate their subcommands), else it is dead code.
    unreachable =
      for file <- files,
          name = file |> Path.basename(".ex") |> Macro.camelize(),
          mod = Module.concat(ArbiterCli.Cmd, name),
          not MapSet.member?(registered, mod),
          not Enum.any?(sources, fn {other, src} ->
            other != file and Regex.match?(~r/\bCmd\.#{name}\b/, src)
          end),
          do: mod

    assert unreachable == [],
           "cmd modules neither registered in ArbiterCli.Verbs nor used by a handler: #{inspect(unreachable)}"
  end

  test "orphans/0 are exactly the handlers no verb reaches" do
    assert Enum.sort(Enum.map(Verbs.orphans(), & &1.handler)) == [ArbiterCli.Cmd.Update]
  end
end
