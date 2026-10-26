defmodule Arbiter.Worker.CliFetcher.BumpTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Worker.CliFetcher.Bump
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Fixtures

  @moduletag :tmp_dir

  setup ctx do
    on_exit(fn ->
      Settings.set_worker_cli_versions(nil)
      Settings.set_worker_cli_manual(nil)
      Settings.set_worker_cli_set_hold(nil)
    end)

    {:ok, opts: Fixtures.base_opts(Path.join(ctx.tmp_dir, "cli-cache"), work_dir: ctx.tmp_dir)}
  end

  defp hits(acc \\ []) do
    receive do
      {:upstream, path} -> hits([path | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serve_both(claude, codex) do
    Fixtures.serve(Map.merge(claude, codex))
  end

  defp claude_only(routes), do: Map.merge(routes, Fixtures.codex_routes(["0.164.0"]))

  test "bumps a pin to the newest stable version, fetches it and records an audit event", %{
    opts: opts
  } do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    Fixtures.serve(claude_only(Fixtures.claude_routes(["2.1.308", "2.1.310"], "2.1.310")))

    assert %{"claude" => {:bumped, "2.1.308", "2.1.310"}, "codex" => {:current, "0.164.0"}} =
             Bump.run(opts)

    assert Settings.worker_cli_versions() == %{"claude" => "2.1.310", "codex" => "0.164.0"}
    assert {:ok, entry} = Cache.lookup("claude", "2.1.310", opts)
    assert :ok = Cache.verify(entry)

    assert [event] = Settings.cli_version_events(cli: "claude")
    assert event.kind == "cli_version_bumped"
    assert event.from_version == "2.1.308"
    assert event.to_version == "2.1.310"
    assert event.detail["integrity"] =~ "sha512-"
    assert Settings.cli_version_events(cli: "codex") == []
  end

  test "never picks a prerelease: a prerelease latest tag falls back to the newest stable", %{
    opts: opts
  } do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.310", "codex" => "0.163.0"})

    codex =
      Map.merge(Fixtures.codex_routes(["0.163.0", "0.164.0"], "0.165.0-alpha.1"), %{
        "/@openai/codex" =>
          Fixtures.json(%{
            "versions" => %{
              "0.163.0" => %{},
              "0.164.0" => %{},
              "0.164.0-linux-x64" => %{},
              "0.165.0-alpha.1" => %{}
            }
          })
      })

    serve_both(Fixtures.claude_routes(["2.1.310"]), codex)

    assert %{"codex" => {:bumped, "0.163.0", "0.164.0"}} = Bump.run(opts)
    assert Settings.worker_cli_versions()["codex"] == "0.164.0"
    refute Enum.any?(hits(), &String.contains?(&1, "alpha"))
  end

  test "an up-to-date pin is left alone and records nothing", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.310", "codex" => "0.164.0"})
    Fixtures.serve(claude_only(Fixtures.claude_routes(["2.1.310"])))

    assert %{"claude" => {:current, "2.1.310"}, "codex" => {:current, "0.164.0"}} = Bump.run(opts)
    assert Settings.cli_version_events() == []
  end

  test "a pin never moves backwards", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.310", "codex" => "0.164.0"})
    Fixtures.serve(claude_only(Fixtures.claude_routes(["2.1.308"], "2.1.308")))

    assert %{"claude" => {:current, "2.1.310"}} = Bump.run(opts)
    assert Settings.worker_cli_versions()["claude"] == "2.1.310"
  end

  test "skipped while the CLI set is held: no pin change, no event, no download", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")
    Fixtures.serve(claude_only(Fixtures.claude_routes(["2.1.308", "2.1.310"], "2.1.310")))

    assert %{"claude" => {:held, "a1b2c3d4"}, "codex" => {:held, "a1b2c3d4"}} = Bump.run(opts)

    assert Settings.worker_cli_versions()["claude"] == "2.1.308"
    assert Settings.cli_version_events() == []
    refute Enum.any?(hits(), &String.contains?(&1, ".tgz"))
  end

  test "a manual pin is skipped, the others still bump", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.163.0"})
    {:ok, _} = Settings.set_worker_cli_manual(["claude"])

    serve_both(
      Fixtures.claude_routes(["2.1.308", "2.1.310"], "2.1.310"),
      Fixtures.codex_routes(["0.163.0", "0.164.0"])
    )

    assert %{"claude" => :manual, "codex" => {:bumped, "0.163.0", "0.164.0"}} = Bump.run(opts)
    assert Settings.worker_cli_versions() == %{"claude" => "2.1.308", "codex" => "0.164.0"}
    assert [%{cli: "codex"}] = Settings.cli_version_events()
    refute Enum.any?(hits(), &String.contains?(&1, "claude-code-linux-x64-2.1.310.tgz"))
  end

  test "a version that fails verification is not pinned and not audited", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})

    routes =
      Fixtures.claude_routes(["2.1.308", "2.1.310"], "2.1.310")
      |> Fixtures.with_claude_tarball("2.1.310", Fixtures.tgz([{"package/claude", "x", 0o755}]))
      |> Map.put(
        "/@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-2.1.310.tgz",
        {200, "application/octet-stream", "not the tarball the document describes"}
      )

    Fixtures.serve(claude_only(routes))

    assert %{"claude" => {:error, {:integrity_mismatch, _}}} = Bump.run(opts)
    assert Settings.worker_cli_versions()["claude"] == "2.1.308"
    assert Settings.cli_version_events() == []
    assert :error = Cache.lookup("claude", "2.1.310", opts)
  end

  test "with no pin yet the newest stable version becomes the pin", %{opts: opts} do
    serve_both(Fixtures.claude_routes(["2.1.310"]), Fixtures.codex_routes(["0.164.0"]))

    assert %{"claude" => {:bumped, nil, "2.1.310"}, "codex" => {:bumped, nil, "0.164.0"}} =
             Bump.run(opts)

    assert Settings.worker_cli_versions() == %{"claude" => "2.1.310", "codex" => "0.164.0"}
  end

  test "announces the pin change so the CLI set can republish", %{opts: opts} do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, Settings.topic())
    Fixtures.serve(claude_only(Fixtures.claude_routes(["2.1.310"])))
    Bump.run(opts)
    assert_receive {:installation_settings_changed, :worker_cli_versions}
  end
end
