defmodule ArbiterCli.ProviderConstraintFlagsTest do
  @moduledoc """
  bd-13pqcp: `--require-provider` / `--exclude-provider` on `arb ticket
  create` / `arb ticket update`, and the constraint on `arb ticket show`.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Create, Update}
  alias ArbiterCli.Output

  @workspace {{"get", "/api/workspaces"},
              {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}

  defp recording_route(verb, path, reply) do
    test = self()

    {{verb, path},
     fn conn ->
       {:ok, body, conn} = Plug.Conn.read_body(conn)
       send(test, {:sent, Jason.decode!(body)})

       conn
       |> Plug.Conn.put_status(elem(reply, 1))
       |> Req.Test.json(elem(reply, 0))
     end}
  end

  describe "arb ticket create" do
    test "--exclude-provider is sent as an exclude constraint (repeatable, comma lists)" do
      stub_routes([
        @workspace,
        recording_route("post", "/api/issues", {%{"id" => "bd-1", "title" => "T"}, 201})
      ])

      {_out, _err, 0} =
        capture(fn ->
          Create.run(["T", "--exclude-provider", "agy", "--exclude-provider", "codex,claude"])
        end)

      assert_receive {:sent, body}
      assert body["provider_constraint"] == %{"exclude" => ["agy", "codex", "claude"]}
    end

    test "--require-provider is sent as a require constraint" do
      stub_routes([
        @workspace,
        recording_route("post", "/api/issues", {%{"id" => "bd-1", "title" => "T"}, 201})
      ])

      {_out, _err, 0} = capture(fn -> Create.run(["T", "--require-provider", "claude"]) end)

      assert_receive {:sent, body}
      assert body["provider_constraint"] == %{"require" => ["claude"]}
    end

    test "no flag sends no constraint at all" do
      stub_routes([
        @workspace,
        recording_route("post", "/api/issues", {%{"id" => "bd-1", "title" => "T"}, 201})
      ])

      {_out, _err, 0} = capture(fn -> Create.run(["T"]) end)

      assert_receive {:sent, body}
      refute Map.has_key?(body, "provider_constraint")
    end

    test "both flags together are refused before any request" do
      {_out, err, exit_code} =
        capture(fn ->
          Create.run(["T", "--require-provider", "claude", "--exclude-provider", "codex"])
        end)

      assert exit_code == 1
      assert err =~ "mutually exclusive"
    end

    test "a worker token's 403 is surfaced, not swallowed" do
      stub_routes([
        @workspace,
        {{"post", "/api/issues"},
         {%{"error" => %{"type" => "forbidden", "message" => "worker tokens may not set that"}},
          403}}
      ])

      {_out, err, exit_code} = capture(fn -> Create.run(["T", "--exclude-provider", "agy"]) end)

      assert exit_code == 1
      assert err =~ "worker tokens may not set that"
    end
  end

  describe "arb ticket update" do
    test "sets a constraint" do
      stub_routes([
        recording_route("patch", "/api/issues/bd-1", {%{"id" => "bd-1", "title" => "T"}, 200})
      ])

      {_out, _err, 0} =
        capture(fn -> Update.run(["bd-1", "--exclude-provider", "agy"]) end)

      assert_receive {:sent, body}
      assert body == %{"provider_constraint" => %{"exclude" => ["agy"]}}
    end

    test "--clear-provider-constraint sends null" do
      stub_routes([
        recording_route("patch", "/api/issues/bd-1", {%{"id" => "bd-1", "title" => "T"}, 200})
      ])

      {_out, _err, 0} = capture(fn -> Update.run(["bd-1", "--clear-provider-constraint"]) end)

      assert_receive {:sent, body}
      assert body == %{"provider_constraint" => nil}
    end

    test "clearing and setting together is refused" do
      {_out, err, exit_code} =
        capture(fn ->
          Update.run(["bd-1", "--require-provider", "claude", "--clear-provider-constraint"])
        end)

      assert exit_code == 1
      assert err =~ "cannot be combined"
    end
  end

  describe "arb ticket show" do
    test "names the constraint" do
      text =
        Output.format_issue_detail(%{
          "id" => "bd-1",
          "title" => "T",
          "provider_constraint" => %{"exclude" => ["gemini", "codex"]}
        })

      assert text =~ "Providers:"
      assert text =~ "exclude gemini, codex"

      assert Output.format_issue_detail(%{
               "id" => "bd-1",
               "title" => "T",
               "provider_constraint" => %{"require" => ["claude"]}
             }) =~ "require claude"
    end

    test "says nothing for a ticket without one" do
      refute Output.format_issue_detail(%{"id" => "bd-1", "title" => "T"}) =~ "Providers:"

      refute Output.format_issue_detail(%{
               "id" => "bd-1",
               "title" => "T",
               "provider_constraint" => nil
             }) =~ "Providers:"
    end
  end
end
