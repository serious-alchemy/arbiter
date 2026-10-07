defmodule ArbiterCli.StrictnessTest do
  @moduledoc """
  The CLI parsing contract (bd-cqw11s), driven from the `ArbiterCli.Verbs`
  registry: every verb, at every probe argv it declares, must exit 1 with
  `unknown option --x for arb <verb>` when handed an unknown flag — and must
  not swallow the token after the flag or reach the network first.

  A verb added to the registry without `:probes` fails here, so a command
  cannot ship with a lenient parse unnoticed.
  """

  # Sync: the probes `File.cd!/1` into a scratch dir so a verb that regresses
  # to a lenient parse and runs for real (`arb init`) cannot write into the repo.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.{Main, Verbs}

  @bogus "--bogus-flag"

  setup do
    original = File.cwd!()
    dir = Path.join(System.tmp_dir!(), "arb-strict-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cd!(dir)

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(dir)
    end)
  end

  defp entries, do: Verbs.all() ++ Verbs.orphans()

  test "every registry entry declares its probes" do
    missing = for %{name: n, probes: nil} <- entries(), do: n

    assert missing == [],
           "verbs without :probes (declare how to reach their flag parser): #{inspect(missing)}"
  end

  test "every registry entry declares workspace: :resolve or :none" do
    for entry <- entries() do
      assert entry.workspace in [:resolve, :none],
             "#{entry.name} must declare workspace: :resolve | :none, got: #{inspect(Map.get(entry, :workspace))}"
    end
  end

  test "verbs with workspace: :none reject -w and --workspace with exit 1" do
    none_entries =
      for %{workspace: :none, kind: kind} = entry <- Verbs.all(),
          kind in [:resource, :shortcut, :legacy],
          do: entry

    refute none_entries == []

    for %{name: name, probes: probes} <- none_entries,
        probe <-
          (case probes do
             [] -> [[]]
             other -> other
           end) do
      for flag <- ["-w", "--workspace"] do
        argv = [name | probe] ++ [flag, "dummy"]
        label = "arb #{Enum.join(argv, " ")}"

        {_out, err, code} =
          capture(fn ->
            try do
              Main.main(argv)
            rescue
              e in ArbiterCli.Output.Halt ->
                reraise e, __STACKTRACE__

              e ->
                flunk("#{label}: crashed instead of rejecting: #{Exception.message(e)}")
            end
          end)

        assert code == 1, "#{label}: expected exit 1, got #{code}; stderr: #{err}"

        assert err =~ "unknown option #{flag} for arb",
               "#{label}: stderr did not name the unknown flag: #{err}"
      end
    end
  end

  test "a workspace-aware verb given a dangling -w or --workspace dies requiring a value" do
    for flag <- ["-w", "--workspace"] do
      {_out, err, code} = capture(fn -> Main.main(["ticket", "list", flag]) end)
      assert code == 1
      assert err =~ "option #{flag} for arb ticket requires a value"
    end
  end

  test "arb server start -w and arb -w server start are rejected" do
    for argv <- [["server", "start", "-w", "foo"], ["-w", "foo", "server", "start"]] do
      {_out, err, code} = capture(fn -> Main.main(argv) end)
      assert code == 1
      assert err =~ "unknown option -w for arb server"
    end
  end

  test "an unknown flag is rejected with exit 1 by every verb, at every probe" do
    for %{name: name, kind: kind, handler: handler, prefix: prefix, probes: probes} <- entries(),
        probe <- probes || [] do
      argv = probe ++ [@bogus]

      label = "arb #{name} #{Enum.join(argv, " ")} (prefix #{inspect(prefix)})"

      {_out, err, code} =
        capture(fn ->
          try do
            case kind do
              :orphan -> handler.run(argv)
              _ -> Main.main([name | argv])
            end
          rescue
            e in ArbiterCli.Output.Halt ->
              reraise e, __STACKTRACE__

            e ->
              flunk("#{label}: ran past the parser instead of rejecting: #{Exception.message(e)}")
          end
        end)

      assert code == 1, "#{label}: expected exit 1, got #{code}; stderr: #{err}"

      assert err =~ "unknown option #{@bogus} for arb",
             "#{label}: stderr did not name the unknown flag: #{err}"
    end
  end

  test "an unknown flag does not swallow the next token" do
    {_out, err, code} = capture(fn -> Main.main(["ticket", "show", "--bogus-flag", "bd-1"]) end)

    assert code == 1
    assert err =~ "unknown option --bogus-flag for arb ticket show"
  end

  test "the error line names the verb the user typed" do
    {_out, err, code} = capture(fn -> Main.main(["ticket", "list", "--nope"]) end)

    assert code == 1
    assert err =~ "unknown option --nope for arb ticket list"
  end

  test "the free-text verbs are the declared opt-outs and keep dashes in the text" do
    test_pid = self()

    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => [%{"id" => "w1", "name" => "default"}]}, 200}},
      {{"post", "/api/messages"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(test_pid, {:posted, Jason.decode!(raw)})
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "m1"})
       end}
    ])

    {out, _err, code} =
      capture(fn -> ArbiterCli.Cmd.Message.run(["bd-1", "use", "--force", "here"]) end)

    assert code == 0
    assert out =~ "Direction sent to bd-1"
    assert_received {:posted, %{"body" => "use --force here"}}
  end
end
