defmodule Arbiter.Sessions.Memory.QuarantineTest do
  @moduledoc """
  Quarantine UX (bd-19qve3, amendment 4): a quarantined memory is a file under
  `<memory_root>/quarantined/`, which no mount ever reads, and restoring one
  re-verifies it before it can be served again.
  """
  use ExUnit.Case, async: false

  import Arbiter.Test.MemoryFixture

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Memory.Checker
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Quarantine
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Sessions.Memory.Verdicts
  alias Arbiter.Sessions.Session

  @moduletag :tmp_dir

  @short "defmodule Short do\n  def hello, do: :world\nend\n"

  setup %{tmp_dir: tmp_dir} do
    checkout = checkout!(%{"lib/short.ex" => @short})
    root = Path.join(tmp_dir, "memory")
    File.mkdir_p!(root)

    prior = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, Path.join(tmp_dir, "sessions"))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, :sessions_root, prior),
        else: Application.delete_env(:arbiter, :sessions_root)
    end)

    opts = [memory_root: root, checkouts: [checkout], ticket_prefixes: []]
    {:ok, root: root, checkout: checkout, opts: opts}
  end

  defp quarantine!(ctx, filename, body, mopts \\ []) do
    write_memory!(
      ctx.root,
      filename,
      "project",
      body,
      Keyword.put_new(mopts, :workspace_id, "ws-1")
    )

    %{quarantined: [{^filename, name}]} = Checker.run(ctx.opts)
    name
  end

  defp quarantined_path(ctx, name), do: Path.join([ctx.root, "quarantined", name])

  defp mounted_project(ctx, session_id) do
    :ok = Memory.mount(%Session{id: session_id, workspace_id: "ws-1"}, memory_root: ctx.root)
    session_id |> Layout.memory_shared_dir() |> Path.join("project") |> File.ls!()
  end

  test "list/1 shows each quarantined memory with its reason, sha and time", ctx do
    name = quarantine!(ctx, "stale.md", "See lib/short.ex:99.")

    assert [entry] = Quarantine.list(ctx.root)
    assert entry.name == name
    assert entry.quarantined_from == "stale.md"
    assert entry.type == "project"
    assert entry.reason =~ "lib/short.ex:99"
    assert entry.sha == head!(ctx.checkout)
    assert is_binary(entry.quarantined_at)
  end

  test "a quarantined memory is never mounted, beside a served one", ctx do
    quarantine!(ctx, "stale.md", "See lib/short.ex:99.")
    write_memory!(ctx.root, "good.md", "project", "See lib/short.ex:2.", workspace_id: "ws-1")
    Checker.run(ctx.opts)

    assert mounted_project(ctx, "sess-q1") == ["good.md"]
  end

  describe "restore/3" do
    test "re-verifies and refuses a memory that is still stale", ctx do
      name = quarantine!(ctx, "stale.md", "See lib/short.ex:99.")

      assert {:error, {:stale, verdict}} = Quarantine.restore(ctx.root, name, ctx.opts)
      assert verdict.reasons |> Enum.join() =~ "lib/short.ex:99"

      assert File.regular?(quarantined_path(ctx, name))
      refute File.exists?(Path.join(ctx.root, "stale.md"))
    end

    test "a fixed memory is restored, stamped, and served again", ctx do
      name = quarantine!(ctx, "stale.md", "See lib/short.ex:99.")
      path = quarantined_path(ctx, name)
      File.write!(path, String.replace(File.read!(path), "lib/short.ex:99", "lib/short.ex:2"))

      assert {:ok, %{memory: "stale.md", verdict: %{status: :ok}}} =
               Quarantine.restore(ctx.root, name, Keyword.put(ctx.opts, :actor, "coordinator"))

      refute File.exists?(path)
      restored = File.read!(Path.join(ctx.root, "stale.md"))
      fields = Frontmatter.fields(restored)

      refute Map.has_key?(fields, "quarantine_reason")
      refute Map.has_key?(fields, "quarantined_from")
      assert fields["restored_by"] == "coordinator"
      assert is_binary(fields["restored_at"])
      assert restored =~ "metadata:\n  type: project\n"

      assert Verdicts.servable?(ctx.root, "stale.md", restored)
      assert mounted_project(ctx, "sess-q2") == ["stale.md"]
    end

    test "code that changed under an anchor needs an explicit re-anchor", ctx do
      contents = memory("project", "Greeting at lib/short.ex:2.", workspace_id: "ws-1")

      promoted =
        Staleness.verify_contents(contents,
          checkouts: [ctx.checkout],
          ticket_prefixes: [],
          establish_anchors: true
        )

      anchored =
        Frontmatter.put(contents, [{"anchors", Staleness.encode_anchors(promoted.anchors)}])

      File.write!(Path.join(ctx.root, "greet.md"), anchored)

      commit!(ctx.checkout, %{"lib/short.ex" => String.replace(@short, ":world", ":mars")})
      %{quarantined: [{"greet.md", name}]} = Checker.run(ctx.opts)

      assert {:error, {:stale, _}} = Quarantine.restore(ctx.root, name, ctx.opts)

      assert {:ok, %{verdict: verdict}} =
               Quarantine.restore(ctx.root, name, Keyword.put(ctx.opts, :reanchor, true))

      fields = ctx.root |> Path.join("greet.md") |> File.read!() |> Frontmatter.fields()
      assert Staleness.decode_anchors(fields["anchors"]) == verdict.anchors
      refute Staleness.decode_anchors(fields["anchors"]) == promoted.anchors
      assert fields["verified_sha"] == head!(ctx.checkout)
    end

    test "refuses to overwrite a live memory of the same name", ctx do
      name = quarantine!(ctx, "stale.md", "See lib/short.ex:99.")
      write_memory!(ctx.root, "stale.md", "project", "A newer memory took the name.")

      assert {:error, :exists} = Quarantine.restore(ctx.root, name, ctx.opts)
      assert File.regular?(quarantined_path(ctx, name))
    end

    test "refuses names outside the quarantine directory", ctx do
      for bad <- ["../stale.md", "a/b.md", "stale.txt", ".hidden.md", ""] do
        assert {:error, :invalid_name} = Quarantine.restore(ctx.root, bad, ctx.opts)
      end

      assert {:error, :not_found} = Quarantine.restore(ctx.root, "never.md", ctx.opts)
    end
  end
end
