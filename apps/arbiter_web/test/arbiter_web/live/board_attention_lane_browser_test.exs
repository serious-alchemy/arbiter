defmodule ArbiterWeb.BoardAttentionLaneBrowserTest do
  @moduledoc """
  The board's Needs-attention swimlane remembers its toggle and its
  coordinator chip per viewer, in browser storage (bd-79w1fs, acceptance
  criterion 5), in a real browser.

  `ArbiterWeb.BoardLifecycleLiveTest` proves the server half of the
  `.AttentionLane` hook's conversation. What it cannot run is the hook: the
  `localStorage` read on mount, the write on each preference the server
  pushes, and the `try`/`catch` that leaves a board without usable storage at
  its defaults. So this boots the real endpoint on a real port, seeds one
  operator-owned and one coordinator-owned attention item, and drives
  `scripts/verify_board_attention_lane.mjs`: collapse and turn the chip on,
  reload, see both restored with the count showing; then make the lane's
  storage throw and see the board render, open at its defaults, and still
  toggle. Then it drives the `.BoardDrag` hook with real drag events: a
  re-rank within Ready that survives a reload, a Backlog → Ready promote, and
  a refused drop on In progress.

  The page is served from the real bundle — the hook is a colocated one — so
  the bundle is rebuilt here by calling `Esbuild.run/2` and `Tailwind.run/2`
  directly, never by shelling out to `mix`, which would deadlock on the build
  lock the surrounding `mix test` already holds.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded rows, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_board_attention_lane.mjs"

  @listener_id :board_attention_lane_listener

  test "the lane's toggle and chip survive a reload, a board without storage still works, and drags land" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    case build_assets() do
      :ok -> drive(node, seed())
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
    end
  end

  # One operator-owned item (approved, auto-merge off: a person merges it) and
  # one coordinator-owned one (merged, waiting on a restart-and-observe). With
  # the chip on the lane holds both.
  defp seed do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "lane-#{n}", prefix: "ln#{n}"})

    {:ok, _operator} =
      ws
      |> active("a person merges this")
      |> Ash.update!(%{pr_ref: "!1"}, action: :open_pr)
      |> Ash.update(%{cause: :awaiting_manual_merge}, action: :raise_attention)

    {:ok, _coordinator} =
      ws |> active("restart and observe") |> Ash.update(%{}, action: :await_verification)

    ready =
      for title <- ["ready a", "ready b", "ready c"] do
        Issue
        |> Ash.create!(%{title: title, workspace_id: ws.id, acceptance: "- lane fixture"})
        |> Ash.update!(%{}, action: :promote)
      end

    backlog =
      Ash.create!(Issue, %{title: "backlog d", workspace_id: ws.id, acceptance: "- lane fixture"})

    %{count: 2, ready: Enum.map(ready, & &1.id), backlog: backlog.id}
  end

  defp active(ws, title) do
    Issue
    |> Ash.create!(%{title: title, workspace_id: ws.id, acceptance: "- lane fixture"})
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
  end

  # The same two commands `mix assets.build` runs, called in-process.
  defp build_assets do
    cond do
      not (Code.ensure_loaded?(Esbuild) and Code.ensure_loaded?(Tailwind)) ->
        {:skipped, "the esbuild/tailwind Mix packages are not loadable"}

      not (File.exists?(Esbuild.bin_path()) and File.exists?(Tailwind.bin_path())) ->
        {:skipped, "no esbuild/tailwind binary on disk — run `mix assets.setup`"}

      Tailwind.run(:arbiter_web, []) != 0 or Esbuild.run(:arbiter_web, []) != 0 ->
        flunk("the asset build failed")

      true ->
        :ok
    end
  end

  defp drive(node, %{count: count, ready: ready, backlog: backlog}) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host.
        [
          @script,
          "--url",
          "http://localhost:#{port}",
          "--count",
          Integer.to_string(count),
          "--ready",
          Enum.join(ready, ","),
          "--backlog",
          backlog,
          "--seconds",
          "30"
        ] ++ shots(),
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_board_attention_lane.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_board_attention_lane.mjs failed:\n\n#{output}")
    end
  end

  # `ARB_BOARD_LANE_SHOTS=<dir>` also writes the open and collapsed board as
  # PNGs, for a person to look at.
  defp shots do
    case System.get_env("ARB_BOARD_LANE_SHOTS") do
      dir when is_binary(dir) and dir != "" -> ["--shots", dir]
      _ -> []
    end
  end

  # `port: 0` lets the kernel pick, so a sibling VM on this host can never lose
  # a race for a port we probed for and had not yet bound.
  defp start_listener! do
    listener =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
          id: @listener_id
        )
      )

    {:ok, {_address, bound}} = ThousandIsland.listener_info(listener)
    bound
  end
end
