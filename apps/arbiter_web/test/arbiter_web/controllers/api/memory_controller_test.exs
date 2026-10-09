defmodule ArbiterWeb.Api.MemoryControllerTest do
  @moduledoc """
  `/api/memory/*` (P-25): the shared-memory promotion queue, quarantine and
  transcript distillation over REST, backing `arb memory`. Every route is
  `:operator` in `ArbiterWeb.ApiPolicy`: a coordinator *session* token (a
  browser-hosted LLM) is refused on the reads and the writes alike, an
  operator-socket token works.
  """
  use ArbiterWeb.ConnCase, async: false

  import Arbiter.Test.MemoryFixture

  alias Arbiter.MCP.Scope
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  @short "defmodule Short do\n  def hello, do: :world\nend\n"
  @session_id "0199aaaa-0000-7000-8000-000000000001"

  setup %{tmp_dir: tmp_dir} do
    memory_root = Path.join(tmp_dir, "memory")
    File.mkdir_p!(memory_root)

    prior =
      for key <- [:sessions_root, :memory_root],
          into: %{},
          do: {key, Application.get_env(:arbiter, key)}

    Application.put_env(:arbiter, :sessions_root, Path.join(tmp_dir, "sessions"))
    Application.put_env(:arbiter, :memory_root, memory_root)

    on_exit(fn ->
      for {key, value} <- prior do
        if value,
          do: Application.put_env(:arbiter, key, value),
          else: Application.delete_env(:arbiter, key)
      end
    end)

    checkout = checkout!(%{"lib/short.ex" => @short})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "memory-rest",
        prefix: "memr",
        config: %{"repo_paths" => %{"short" => checkout}}
      })

    {:ok, memory_root: memory_root, ws: ws}
  end

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp operator_conn, do: as(Scope.mint_coordinator(nil, operator: true))
  defp proofless_conn, do: as(Scope.mint_coordinator(nil))
  defp session_conn, do: as(Scope.mint_coordinator(nil, session_id: @session_id))

  defp candidate!(session_id, filename, type, body, opts \\ []) do
    write_memory!(Layout.memory_candidates_dir(session_id), filename, type, body, opts)
  end

  defp quarantine!(ctx) do
    write_memory!(ctx.memory_root, "stale.md", "project", "See lib/short.ex:99.",
      workspace_id: ctx.ws.id
    )

    %{quarantined: [{"stale.md", name}]} = Checker.run(memory_root: ctx.memory_root)
    name
  end

  @routes [
    {:get, "/api/memory/pending", %{}},
    {:get, "/api/memory/pending/diff", %{"id" => "sess-1/habit.md"}},
    {:post, "/api/memory/pending/apply", %{"id" => "sess-1/habit.md"}},
    {:post, "/api/memory/pending/reject", %{"id" => "sess-1/habit.md", "reason" => "no"}},
    {:get, "/api/memory/quarantine", %{}},
    {:post, "/api/memory/quarantine/restore", %{"name" => "x.md"}},
    {:post, "/api/memory/distill", %{"session_id" => "sess-1"}}
  ]

  describe "who may call" do
    test "a coordinator session token is refused on all seven routes, and nothing changes",
         ctx do
      path = candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")
      quarantined = quarantine!(ctx)

      for {verb, route, params} <- @routes do
        conn = dispatch(session_conn(), @endpoint, verb, route, params)
        assert json_response(conn, 403), "#{verb} #{route} admitted a session token"
      end

      assert File.exists?(path)
      refute File.exists?(Path.join(ctx.memory_root, "habit.md"))
      assert File.exists?(Path.join([ctx.memory_root, "quarantined", quarantined]))
    end

    test "a coordinator token without operator proof is refused" do
      for {verb, route, params} <- @routes do
        conn = dispatch(proofless_conn(), @endpoint, verb, route, params)
        assert json_response(conn, 403), "#{verb} #{route} admitted a proofless token"
      end
    end

    test "no token is a 401" do
      conn = get(Phoenix.ConnTest.build_conn(), "/api/memory/pending")
      assert json_response(conn, 401)
    end
  end

  describe "pending queue" do
    test "lists and shows a candidate" do
      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")

      body = json_response(get(operator_conn(), "/api/memory/pending"), 200)
      assert %{"count" => 1, "candidates" => [%{"id" => "sess-1/habit.md"}]} = body

      body =
        json_response(get(operator_conn(), "/api/memory/pending/diff?id=sess-1/habit.md"), 200)

      assert body["content"] =~ "Prefer small PRs."
      assert %{"status" => "ok"} = body["verification"]
    end

    test "an unknown state is a 422 and a missing candidate a 404" do
      assert json_response(get(operator_conn(), "/api/memory/pending?state=bogus"), 422)

      assert json_response(
               get(operator_conn(), "/api/memory/pending/diff?id=sess-1/none.md"),
               404
             )
    end

    test "apply promotes with provenance, and replacing needs overwrite", ctx do
      candidate!("sess-1", "proj.md", "project", "Greeting at lib/short.ex:2.",
        workspace_id: ctx.ws.id
      )

      conn = post(operator_conn(), "/api/memory/pending/apply", %{id: "sess-1/proj.md"})

      assert %{"promoted" => true, "memory" => "proj.md", "status" => "ok"} =
               json_response(conn, 200)

      assert File.exists?(Path.join(ctx.memory_root, "proj.md"))

      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")
      File.write!(Path.join(ctx.memory_root, "habit.md"), "old\n")

      conn = post(operator_conn(), "/api/memory/pending/apply", %{id: "sess-1/habit.md"})
      assert %{"error" => %{"type" => "conflict"}} = json_response(conn, 409)

      conn =
        post(operator_conn(), "/api/memory/pending/apply", %{
          id: "sess-1/habit.md",
          overwrite: true
        })

      assert %{"promoted" => true} = json_response(conn, 200)
    end

    test "a stale candidate is refused with the reasons", ctx do
      candidate!("sess-1", "proj.md", "project", "See lib/short.ex:100.", workspace_id: ctx.ws.id)

      conn = post(operator_conn(), "/api/memory/pending/apply", %{id: "sess-1/proj.md"})

      assert %{"error" => %{"type" => "conflict", "message" => message}} =
               json_response(conn, 409)

      assert message =~ "lib/short.ex:100"
    end

    test "reject needs a reason, then keeps the candidate under state=rejected" do
      candidate!("sess-1", "habit.md", "feedback", "Prefer small PRs.")

      conn = post(operator_conn(), "/api/memory/pending/reject", %{id: "sess-1/habit.md"})
      assert json_response(conn, 422)

      conn =
        post(operator_conn(), "/api/memory/pending/reject", %{
          id: "sess-1/habit.md",
          reason: "vague"
        })

      assert %{"rejected" => true} = json_response(conn, 200)

      body = json_response(get(operator_conn(), "/api/memory/pending?state=rejected"), 200)
      assert %{"count" => 1, "candidates" => [%{"rejection_reason" => "vague"}]} = body
    end
  end

  describe "quarantine" do
    test "lists with reasons; restore refuses until fixed, then serves it", ctx do
      name = quarantine!(ctx)

      body = json_response(get(operator_conn(), "/api/memory/quarantine"), 200)
      assert %{"count" => 1, "quarantined" => [%{"name" => ^name, "reason" => reason}]} = body
      assert reason =~ "lib/short.ex:99"

      conn = post(operator_conn(), "/api/memory/quarantine/restore", %{name: name})
      assert %{"error" => %{"message" => message}} = json_response(conn, 409)
      assert message =~ "lib/short.ex:99"

      path = Path.join([ctx.memory_root, "quarantined", name])
      File.write!(path, String.replace(File.read!(path), "lib/short.ex:99", "lib/short.ex:2"))

      conn = post(operator_conn(), "/api/memory/quarantine/restore", %{name: name})
      assert %{"restored" => true, "memory" => "stale.md"} = json_response(conn, 200)
    end

    test "restoring a name that is not quarantined is a 404" do
      conn = post(operator_conn(), "/api/memory/quarantine/restore", %{name: "nope.md"})
      assert json_response(conn, 404)
    end
  end

  describe "distill" do
    test "model calls disabled on the server is a 503; a missing session_id a 422" do
      conn = post(operator_conn(), "/api/memory/distill", %{session_id: @session_id})
      assert %{"error" => %{"message" => message}} = json_response(conn, 503)
      assert message =~ "disabled"

      assert json_response(post(operator_conn(), "/api/memory/distill", %{}), 422)
    end

    test "a bound that is not a positive integer is a 422" do
      conn =
        post(operator_conn(), "/api/memory/distill", %{session_id: @session_id, max_bytes: 0})

      assert json_response(conn, 422)
    end
  end
end
