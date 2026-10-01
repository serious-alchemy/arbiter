defmodule ArbiterWeb.QuotaTopbarBrowserTest do
  @moduledoc """
  The status bar's quota chip in a real browser at real viewports (bd-i2gwwn,
  was bd-gukyy1's stacked rows).

  `ArbiterWeb.QuotaTopbarTest` proves the markup — a ring object per shown
  provider, the popover's bars, the ARIA. It cannot show that the 36px chip
  fits inside the 46px status bar at one height for one, two and three
  providers, that the wordmark, live badge, inbox trigger and theme toggle
  still fit beside it at `lg` and `xl` without overlap or overflow, that the
  ring colours resolve in both themes, or that the popover opens and closes on
  a click, Enter, a tap, Escape and an outside click and stays in the viewport.
  `ConnCase` has no layout engine and doesn't run `JS` commands.

  So this boots the real endpoint on a real port, seeds Claude, Antigravity
  and Codex quotas on a default workspace that runs all three, and drives
  `scripts/verify_quota_topbar.mjs` against it, then re-runs its fit checks
  with the override hiding one and then two providers. Skipped, not failed,
  where there is no Chromium (the script exits `3`) or no esbuild/tailwind
  binary. Set `ARB_QUOTA_SHOTS=<dir>` to also get PNGs.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection to read the seeded quotas, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.QuotaFixtures

  alias Arbiter.Tasks.Workspace

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_quota_topbar.mjs"

  @listener_id :quota_topbar_listener

  test "the quota chip fits the status bar for 1-3 providers and its popover works" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    ws =
      Ash.create!(Workspace, %{
        name: "default",
        config: %{"agent" => %{"type" => ["claude", "gemini", "codex"]}}
      })

    now = DateTime.to_unix(DateTime.utc_now())

    {:ok, _} =
      Arbiter.Quota.capture(ws.id, [
        {"anthropic-ratelimit-unified-5h-utilization", "0.42"},
        {"anthropic-ratelimit-unified-5h-reset", to_string(now + 9_000)},
        {"anthropic-ratelimit-unified-7d-utilization", "0.18"},
        {"anthropic-ratelimit-unified-7d-reset", to_string(now + 302_400)}
      ])

    antigravity_quota!(ws)

    codex_quota!(ws, session_used_percent: 30.0)

    case build_assets() do
      :ok ->
        port = start_listener!()
        start_patch_ticker!(ws)

        if drive(node, port, ["--expect", "claude,antigravity,codex"]) == :ran do
          {:ok, _} = Arbiter.Settings.set_quota_providers_hidden(["codex"])
          drive(node, port, ["--expect", "claude,antigravity", "--full", "0"])

          {:ok, _} = Arbiter.Settings.set_quota_providers_hidden(["antigravity", "codex"])
          drive(node, port, ["--expect", "claude", "--full", "0"])
        end

      {:skipped, why} ->
        IO.puts("\n[skipped] #{why}")
    end
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

  defp drive(node, port, args) do
    shots =
      case System.get_env("ARB_QUOTA_SHOTS") do
        nil -> []
        dir -> ["--shots", dir]
      end

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host.
        [@script, "--url", "http://localhost:#{port}", "--seconds", "30"] ++ args ++ shots,
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_quota_topbar.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))
        :skipped

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"
        :ran

      _other ->
        flunk("verify_quota_topbar.mjs failed:\n\n#{output}")
    end
  end

  # A changing Claude reading broadcast every 150ms, so the page is re-rendered
  # under the script while it holds the popover open — the claim that the
  # `JS`-opened popover survives a server patch. Broadcast only, no DB.
  defp start_patch_ticker!(ws) do
    [claude] =
      ws.id
      |> Arbiter.Quota.list_latest_for_workspace()
      |> Enum.filter(&(&1.provider == "claude"))

    start_supervised!(
      {Task,
       fn ->
         Stream.iterate(1, &(rem(&1, 60) + 1))
         |> Enum.each(fn n ->
           view = %{claude | utilization_5h: n / 100}

           Phoenix.PubSub.broadcast(
             Arbiter.PubSub,
             "quota:#{ws.id}",
             {:quota_updated, ws.id, view}
           )

           Process.sleep(150)
         end)
       end}
    )
  end

  # `port: 0` lets the kernel pick; the bound port is read back off Thousand
  # Island so a sibling VM can never lose a race for it.
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
