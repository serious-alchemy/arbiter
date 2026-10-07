defmodule Arbiter.Tasks.WorkspacesTest do
  @moduledoc """
  The one omitted-workspace rule (parity audit P-04, operator ruling on
  bd-26s98f): reads default to ALL workspaces, writes never fall back to the
  workspace literally named `default`, a bound scope is always confined, and
  every surface accepts an id OR a name.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspaces

  defp make_ws(name, prefix) do
    {:ok, ws} = Ash.create(Workspace, %{name: name, prefix: prefix})
    ws
  end

  defp coordinator(ws_id \\ nil), do: %Scope{tier: :coordinator, workspace_id: ws_id}

  describe "with several workspaces, one literally named `default`" do
    setup do
      # Other tests may leave rows behind in the shared sandbox; the rule is
      # about the set that exists, so pin the fixture's own names.
      a = make_ws("default", "df")
      b = make_ws("emricare", "em")
      {:ok, a: a, b: b}
    end

    test "a write naming nothing fails instead of landing in `default`", %{a: a, b: b} do
      assert {:error, {:invalid, msg}} = Workspaces.resolve(coordinator(), nil, mode: :write)
      assert msg =~ "multiple workspaces; pass workspace (name or id)"
      assert msg =~ a.name
      assert msg =~ b.name
    end

    test "a blank arg counts as omitted" do
      assert {:error, {:invalid, _}} = Workspaces.resolve(coordinator(), "  ", mode: :write)
      assert {:ok, nil} = Workspaces.resolve(coordinator(), "", mode: :read)
    end

    test "a read naming nothing means ALL workspaces (nil)" do
      assert {:ok, nil} = Workspaces.resolve(coordinator(), nil, mode: :read)
    end

    test "an explicit id or name resolves, in both modes", %{b: b} do
      for mode <- [:read, :write], ref <- [b.id, b.name] do
        assert {:ok, id} = Workspaces.resolve(coordinator(), ref, mode: mode)
        assert id == b.id
      end
    end

    test "an unknown reference is not_found, never an empty result" do
      assert {:error, {:not_found, msg}} = Workspaces.resolve(coordinator(), "nope", mode: :read)
      assert msg =~ "nope"
      assert {:error, {:not_found, _}} = Workspaces.resolve(coordinator(), "nope", mode: :write)
    end

    test "a bound scope resolves to its own workspace with no arg, both modes", %{b: b} do
      scope = coordinator(b.id)
      assert {:ok, b_id} = Workspaces.resolve(scope, nil, mode: :read)
      assert b_id == b.id
      assert {:ok, ^b_id} = Workspaces.resolve(scope, nil, mode: :write)
    end

    test "a bound scope may name its own workspace by id or name", %{b: b} do
      scope = coordinator(b.id)
      assert {:ok, b_id} = Workspaces.resolve(scope, b.name, mode: :write)
      assert b_id == b.id
      assert {:ok, ^b_id} = Workspaces.resolve(scope, b.id, mode: :read)
    end

    test "a bound scope naming another workspace is unauthorized (403 / -32003)", %{a: a, b: b} do
      scope = coordinator(b.id)

      for mode <- [:read, :write], ref <- [a.id, a.name] do
        assert {:error, {:unauthorized, msg}} = Workspaces.resolve(scope, ref, mode: mode)
        assert msg =~ "bound to a single workspace"
      end
    end
  end

  describe "with a sole workspace" do
    test "a write with no arg lands in it, whatever it is called" do
      only = make_ws("only-#{System.unique_integer([:positive])}", "on")
      keep_only(only)

      assert {:ok, id} = Workspaces.resolve(coordinator(), nil, mode: :write)
      assert id == only.id
    end

    test "with none, a write is invalid and a read is all (nil)" do
      keep_only(nil)
      assert {:error, {:invalid, msg}} = Workspaces.resolve(coordinator(), nil, mode: :write)
      assert msg =~ "no workspaces"
      assert {:ok, nil} = Workspaces.resolve(coordinator(), nil, mode: :read)
    end
  end

  describe "resolve_default/2 (single-workspace views such as quota)" do
    test "tolerates several workspaces, but never escapes a bound scope or hides a typo" do
      a = make_ws("default", "df")
      b = make_ws("emricare", "em")

      assert {:ok, id} = Workspaces.resolve_default(coordinator(), nil)
      assert id == a.id
      assert {:ok, id} = Workspaces.resolve_default(coordinator(), "emricare")
      assert id == b.id
      assert {:ok, id} = Workspaces.resolve_default(coordinator(b.id), nil)
      assert id == b.id
      assert {:error, {:unauthorized, _}} = Workspaces.resolve_default(coordinator(b.id), a.id)
      assert {:error, {:not_found, _}} = Workspaces.resolve_default(coordinator(), "nope")
    end

    test "is invalid, naming the candidates, when no default can be told" do
      make_ws("one", "o1")
      make_ws("two", "t2")
      keep_only_named(["one", "two"])

      assert {:error, {:invalid, msg}} = Workspaces.resolve_default(coordinator(), nil)
      assert msg =~ "multiple workspaces" and msg =~ "one" and msg =~ "two"
    end
  end

  describe "arg/1" do
    test "`workspace` wins, `workspace_id` is the alias, blanks are nil" do
      assert Workspaces.arg(%{"workspace" => "a", "workspace_id" => "b"}) == "a"
      assert Workspaces.arg(%{"workspace_id" => "b"}) == "b"
      assert Workspaces.arg(%{"workspace" => " ", "workspace_id" => "b"}) == "b"
      assert Workspaces.arg(%{}) == nil
    end
  end

  describe "default/0 (display + quota lookups only)" do
    test "is the sole workspace, else the one named `default`, else ambiguous" do
      a = make_ws("default", "df")
      _b = make_ws("emricare", "em")
      assert {:ok, %Workspace{id: id}} = Workspaces.default()
      assert id == a.id
    end
  end

  # The sandbox may carry rows from boot seeding; destroy everything but `keep`.
  defp keep_only(keep) do
    for ws <- Ash.read!(Workspace), is_nil(keep) or ws.id != keep.id do
      Ash.destroy!(ws, action: :destroy)
    end

    :ok
  end

  defp keep_only_named(names) do
    for ws <- Ash.read!(Workspace), ws.name not in names, do: Ash.destroy!(ws, action: :destroy)
    :ok
  end
end
