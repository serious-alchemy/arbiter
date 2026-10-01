defmodule ArbiterWeb.SettingsPageBrowserTest do
  @moduledoc """
  The `/settings` page in a real browser at 1280px and at a phone width
  (bd-3tnoi9).

  `ArbiterWeb.SettingsLiveTest` proves the page's data and its saves. What
  `ConnCase` has no layout engine to show is that every section is actually
  drawn, that nothing is pushed past the viewport at either width, that the
  theme switcher really flips `html[data-theme]`, and that a value typed into a
  real input and saved comes back through the socket.

  Boots the real endpoint on a real port and drives `scripts/verify_settings_page.mjs`
  against it (`--mutate 1`: the sandbox rolls the save back). The bundle is
  rebuilt in-process with `Esbuild.run/2` and `Tailwind.run/2` — never by
  shelling out to `mix`, which would deadlock on the build lock the surrounding
  `mix test` holds.

  Skipped, not failed, where there is no Chromium (the script exits `3`) or no
  esbuild/tailwind binary to build the bundle with.
  """
  # async: false — Bandit's connection processes need the shared sandbox
  # connection, and the listener binds a real port.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Board.Autopilot

  @moduletag :browser
  @moduletag timeout: 300_000

  @root Path.expand("../../../../..", __DIR__)
  @script "scripts/verify_settings_page.mjs"

  test "every section is drawn, nothing overflows, and a save round-trips" do
    node = System.find_executable("node") || flunk("node is required by the :browser tag")

    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    case build_assets() do
      :ok -> drive(node)
      {:skipped, why} -> IO.puts("\n[skipped] #{why}")
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

  defp drive(node) do
    port = start_listener!()

    {output, status} =
      System.cmd(
        node,
        # `localhost`, not `127.0.0.1`: Phoenix checks the LiveView socket's
        # Origin against the endpoint's configured host.
        [@script, "--url", "http://localhost:#{port}", "--mutate", "1", "--seconds", "30"] ++
          shots_args(),
        cd: @root,
        stderr_to_stdout: true
      )

    if System.get_env("ARB_SHOW_TRANSCRIPT") do
      IO.puts("\n--- verify_settings_page.mjs ---\n" <> output)
    end

    case status do
      3 ->
        IO.puts("\n[skipped] " <> String.trim(output))

      0 ->
        assert output =~ "RESULT: PASS"
        refute output =~ ": FAIL"

      _other ->
        flunk("verify_settings_page.mjs failed:\n\n#{output}")
    end
  end

  # `ARB_SHOTS_DIR=<dir>` keeps a real PNG capture per width, for looking at.
  defp shots_args do
    case System.get_env("ARB_SHOTS_DIR") do
      nil -> []
      dir -> ["--shots", dir]
    end
  end

  # `port: 0` lets the kernel pick; the bound port is read back off Thousand
  # Island, so a sibling VM on this host can never lose a race for it.
  defp start_listener! do
    listener =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0},
          id: :settings_page_listener
        )
      )

    {:ok, {_address, bound}} = ThousandIsland.listener_info(listener)
    bound
  end
end
