defmodule ArbiterCli.MainTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Main

  @issues %{"data" => [%{"id" => "bd-1", "title" => "T", "state" => "queued"}]}

  describe "arb <resource> <verb>" do
    test "ticket list dispatches to the ticket resource" do
      stub_get("/api/issues", @issues)
      {out, _err, code} = capture(fn -> Main.main(["ticket", "list"]) end)
      assert code == 0
      assert out =~ "bd-1"
    end

    # bd-9so315: the top-level shortcut, the form the escalation body tells the
    # coordinator to run.
    test "arb verify <id> reaches the issue verify endpoint" do
      stub_post(
        "/api/issues/bd-1/verify",
        %{"id" => "bd-1", "title" => "T", "state" => "closed"},
        200
      )

      {out, _err, code} =
        capture(fn -> Main.main(["verify", "bd-1", "--observed", "saw it live"]) end)

      assert code == 0
      assert out =~ "bd-1"
    end
  end

  describe "arb ticket, and arb issue as its deprecated alias (bd-4jojpw)" do
    @deprecation "arb: note: `arb issue` is deprecated; use `arb ticket` (same subcommands).\n"

    # Every request answers 200 with a small record, so each verb gets as far
    # down its real path as a generic body allows — and a raise is recorded
    # rather than failing the test, since it must merely be the same raise.
    defp stub_echo do
      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        Req.Test.json(conn, %{
          "id" => "bd-1",
          "title" => "T",
          "state" => "queued",
          "data" => [],
          "task" => %{"id" => "bd-1"},
          "worker" => %{},
          "machine" => %{}
        })
      end)
    end

    defp run_cli(argv) do
      stub_echo()

      capture(fn ->
        try do
          Main.main(argv)
        rescue
          e in ArbiterCli.Output.Halt -> reraise e, __STACKTRACE__
          e -> IO.puts("raised: " <> Exception.message(e))
        end
      end)
    end

    test "arb ticket <verb> behaves exactly like arb issue <verb>, minus one deprecation line" do
      for verb <- ArbiterCli.Cmd.Issue.subcommands(),
          args <- [[], ["bd-1"], ["bd-1", "--json"]] do
        {t_out, t_err, t_code} = run_cli(["ticket", verb | args])
        {i_out, i_err, i_code} = run_cli(["issue", verb | args])

        label = "arb {ticket,issue} #{Enum.join([verb | args], " ")}"
        assert i_out == t_out, label
        assert i_code == t_code, label
        assert i_err == @deprecation <> t_err, label
        refute t_err =~ "deprecated", label
      end
    end

    test "arb ticket list reaches the list endpoint with no note" do
      stub_get("/api/issues", @issues)
      {out, err, code} = capture(fn -> Main.main(["ticket", "list"]) end)
      assert code == 0
      assert out =~ "bd-1"
      assert err == ""
    end

    test "arb issue list still works and prints exactly one deprecation line on stderr" do
      stub_get("/api/issues", @issues)
      {out, err, code} = capture(fn -> Main.main(["issue", "list"]) end)
      assert code == 0
      assert out =~ "bd-1"
      assert err == @deprecation
    end

    test "arb ticket with no subcommand names the ticket resource" do
      {_out, err, code} = capture(fn -> Main.main(["ticket"]) end)
      assert code == 1
      assert err =~ "ticket requires a subcommand"
    end

    test "arb ticket --help documents the ticket grammar" do
      {out, _err, code} = capture(fn -> Main.main(["ticket", "--help"]) end)
      assert code == 0
      assert out =~ "arb ticket list"
      refute out =~ "arb issue list"
    end
  end

  describe "global --workspace / -w flag" do
    setup do
      prev = System.get_env("ARB_WORKSPACE")

      on_exit(fn ->
        if prev,
          do: System.put_env("ARB_WORKSPACE", prev),
          else: System.delete_env("ARB_WORKSPACE")
      end)

      :ok
    end

    test "-w <name> before the subcommand sets ARB_WORKSPACE and dispatches correctly" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} = capture(fn -> Main.main(["-w", "myws", "ticket", "list"]) end)
      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "--workspace <name> before the subcommand works" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["--workspace", "myws", "ticket", "list"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "flag takes precedence over ARB_WORKSPACE env" do
      System.put_env("ARB_WORKSPACE", "default")

      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-default", "name" => "default", "prefix" => "bd"},
              %{"id" => "ws-other", "name" => "other", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["-w", "other", "ticket", "list"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "other"
    end

    test "-w after the resource also works" do
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-1", "name" => "myws", "prefix" => "xx"}
            ]
          }, 200}}
      ])

      {_out, _err, code} =
        capture(fn -> Main.main(["ticket", "list", "-w", "myws"]) end)

      assert code == 0
      assert System.get_env("ARB_WORKSPACE") == "myws"
    end

    test "unknown workspace name fails with a clear error" do
      # Use --tracker to force workspace resolution (list without --tracker fetches
      # issues first and never resolves the workspace unless needed).
      stub_routes([
        {{"get", "/api/issues"}, {%{"data" => []}, 200}},
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-1", "name" => "realws", "prefix" => "bd"}]}, 200}}
      ])

      {_out, err, code} =
        capture(fn -> Main.main(["-w", "unknown-name", "ticket", "list", "--tracker"]) end)

      assert code != 0
      assert err =~ "unknown-name"
    end
  end

  describe "legacy flat commands" do
    test "arb list runs arb ticket list and prints a migration note" do
      stub_get("/api/issues", @issues)

      {out, err, code} = capture(fn -> Main.main(["list"]) end)
      assert code == 0
      assert out =~ "bd-1"
      assert err =~ "`arb list` is now `arb ticket list`"
    end

    test "arb update with no id redirects to server deploy" do
      # We only assert the redirect note; deploy will fail fast without a root,
      # which is fine — the routing is what we're checking. Every command it
      # would run fails, so it never touches this checkout's git for real.
      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts -> {"stubbed", 1} end)
      {_out, err, _code} = capture(fn -> Main.main(["update"]) end)
      assert err =~ "`arb update` is now `arb server deploy`"
    end
  end

  describe "unknown command" do
    test "prints suggestions and halts 2" do
      {_out, err, code} = capture(fn -> Main.main(["isue"]) end)
      assert code == 2
      assert err =~ "unknown command: isue"
    end

    test "worker is now a real command — not an unknown themed alias" do
      {_out, err, code} = capture(fn -> Main.main(["worker"]) end)
      assert code == 1
      assert err =~ "worker requires a subcommand"
    end
  end
end
