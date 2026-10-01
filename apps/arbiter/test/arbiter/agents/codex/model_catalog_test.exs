defmodule Arbiter.Agents.Codex.ModelCatalogTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.Codex.Config
  alias Arbiter.Agents.Codex.ModelCatalog
  alias Arbiter.Tasks.Workspace

  @quota_stub Arbiter.Quota.Codex.HTTP

  # The model list `~/.codex/models_cache.json` held on the arbiter host
  # (client 0.153.4, fetched 2026-09-30) for a ChatGPT *free* account — slugs,
  # visibility and priority only.
  @host_free_models [
    {"gpt-reserve", "hide", 4},
    {"gpt-5.6-terra", "list", 8},
    {"gpt-5.6-luna", "list", 9},
    {"gpt-5.5", "list", 13},
    {"codex-auto-review", "hide", 43}
  ]

  # The live default workspace's override (all 400/404 on the free plan).
  @legacy_override %{
    "economy" => "gpt-5.4-mini",
    "standard" => "gpt-5.5",
    "premium" => "gpt-5.5"
  }

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "arb-cxhome-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)

    prev_catalog = Application.get_env(:arbiter, :codex_model_catalog)
    prev_stub = Application.get_env(:arbiter, :codex_quota_http_stub)
    prev_key = System.get_env("OPENAI_API_KEY")

    Application.put_env(:arbiter, :codex_model_catalog, codex_home: home)
    Application.put_env(:arbiter, :codex_quota_http_stub, true)
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      restore_app_env(:codex_model_catalog, prev_catalog)
      restore_app_env(:codex_quota_http_stub, prev_stub)
      if prev_key, do: System.put_env("OPENAI_API_KEY", prev_key)
      File.rm_rf(home)
    end)

    Config.clear()
    {:ok, home: home}
  end

  describe "read/2" do
    test "returns every slug and the listed ones in priority order", %{home: home} do
      write_cache!(home, @host_free_models)

      assert {:ok, catalog} = ModelCatalog.read(home)
      assert Enum.sort(catalog.slugs) == Enum.sort(Enum.map(@host_free_models, &elem(&1, 0)))
      assert catalog.listed == ["gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
    end

    test "is :missing without a cache file", %{home: home} do
      assert ModelCatalog.read(home) == {:error, :missing}
    end

    test "is :invalid for an unparseable file", %{home: home} do
      File.write!(Path.join(home, "models_cache.json"), "{not json")
      assert ModelCatalog.read(home) == {:error, :invalid}
    end

    test "is :stale once fetched_at is older than the freshness window", %{home: home} do
      write_cache!(home, @host_free_models, DateTime.add(DateTime.utc_now(), -30, :day))
      assert ModelCatalog.read(home) == {:error, :stale}
    end
  end

  describe "backend/2" do
    test "ChatGPT login with no API key is :chatgpt", %{home: home} do
      write_auth!(home, "chatgpt")
      assert ModelCatalog.backend(home, false) == :chatgpt
    end

    test "an API key Arbiter exports makes it :openai_api", %{home: home} do
      write_auth!(home, "chatgpt")
      assert ModelCatalog.backend(home, true) == :openai_api
    end

    test "a non-OpenAI model_provider in config.toml is :custom", %{home: home} do
      write_auth!(home, "chatgpt")

      File.write!(Path.join(home, "config.toml"), """
      model = "qwen3-coder"
      model_provider = "ollama"

      [model_providers.ollama]
      base_url = "http://localhost:11434/v1"
      """)

      assert ModelCatalog.backend(home, false) == :custom
    end

    test "model_provider inside a table does not count", %{home: home} do
      write_auth!(home, "chatgpt")

      File.write!(Path.join(home, "config.toml"), """
      [profiles.local]
      model_provider = "ollama"
      """)

      assert ModelCatalog.backend(home, false) == :chatgpt
    end

    test "no auth.json and no provider is :unknown", %{home: home} do
      assert ModelCatalog.backend(home, false) == :unknown
    end
  end

  describe "plan/1 reads the stored Codex quota snapshot" do
    test "is the plan the usage endpoint reported" do
      ws = Ash.create!(Workspace, %{name: "plan-free"})
      record_quota!(ws, "free")

      assert ModelCatalog.plan(ws.id) == "free"
    end

    test "is nil before any snapshot exists" do
      ws = Ash.create!(Workspace, %{name: "plan-none"})
      assert ModelCatalog.plan(ws.id) == nil
    end
  end

  describe "Config.model_for_tier/1 on the ChatGPT backend" do
    setup %{home: home} do
      write_auth!(home, "chatgpt")
      write_cache!(home, @host_free_models)
      :ok
    end

    test "free plan: the legacy override is replaced with valid models" do
      ws = workspace_with_override!("free-legacy", @legacy_override)
      record_quota!(ws, "free")
      Config.put_active(ws)

      # gpt-5.4-mini is absent from the catalog (400 on a ChatGPT account);
      # gpt-5.5 is listed but 404s on the free plan.
      assert Config.model_for_tier("economy") == "gpt-5.6-luna"
      assert Config.model_for_tier("standard") == "gpt-5.6-terra"
      assert Config.model_for_tier("premium") == "gpt-5.6-terra"
      assert Config.model_for_tier("flagship") == "gpt-5.6-terra"
    end

    test "a paid plan keeps a catalog model the free plan cannot use" do
      ws = workspace_with_override!("plus-legacy", @legacy_override)
      record_quota!(ws, "plus")
      Config.put_active(ws)

      assert Config.model_for_tier("standard") == "gpt-5.5"
      assert Config.model_for_tier("economy") == "gpt-5.6-luna"
    end

    test "built-in defaults are kept when the catalog lists them" do
      ws = Ash.create!(Workspace, %{name: "free-defaults"})
      record_quota!(ws, "free")
      Config.put_active(ws)

      assert Config.model_for_tier("economy") == "gpt-5.6-luna"
      assert Config.model_for_tier("flagship") == "gpt-5.6-terra"
    end

    test "falls back to the best listed model when the tier default is missing", %{home: home} do
      write_cache!(home, [{"gpt-5.6-terra", "list", 8}, {"gpt-5.5", "list", 13}])
      ws = Ash.create!(Workspace, %{name: "free-no-luna"})
      record_quota!(ws, "free")
      Config.put_active(ws)

      assert Config.model_for_tier("economy") == "gpt-5.6-terra"
    end

    test "a missing cache skips catalog validation but keeps the plan check", %{home: home} do
      File.rm!(Path.join(home, "models_cache.json"))
      ws = workspace_with_override!("free-nocache", @legacy_override)
      record_quota!(ws, "free")
      Config.put_active(ws)

      # Unknowable without the cache — the first turn's 400 is classified.
      assert Config.model_for_tier("economy") == "gpt-5.4-mini"
      assert Config.model_for_tier("standard") == "gpt-5.6-terra"
    end
  end

  describe "backend neutrality" do
    test "a custom backend gets no OpenAI default and its own override untouched", %{home: home} do
      write_auth!(home, "chatgpt")
      write_cache!(home, @host_free_models)
      File.write!(Path.join(home, "config.toml"), ~s(model_provider = "ollama"\n))

      ws = workspace_with_override!("ollama", %{"premium" => "qwen3-coder:30b"})
      record_quota!(ws, "free")
      Config.put_active(ws)

      assert Config.model_for_tier("premium") == "qwen3-coder:30b"
      assert Config.model_for_tier("economy") == nil
    end

    test "an API-key backend is not held to the ChatGPT catalog", %{home: home} do
      write_auth!(home, "chatgpt")
      write_cache!(home, @host_free_models)

      ws =
        Ash.create!(Workspace, %{
          name: "apikey",
          config: %{
            "agent" => %{
              "config" => %{
                "api_keys" => ["sk-test"],
                "codex" => %{"tier_models" => %{"economy" => "gpt-5.4-mini"}}
              }
            }
          }
        })

      Config.put_active(ws)

      assert Config.model_for_tier("economy") == "gpt-5.4-mini"
    end
  end

  describe "Codex.default_argv/2 pre-flight" do
    setup %{home: home} do
      write_auth!(home, "chatgpt")
      write_cache!(home, @host_free_models)

      bin = Path.join(home, "bin")
      File.mkdir_p!(bin)
      codex = Path.join(bin, "codex")
      File.write!(codex, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex, 0o755)

      old_path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> old_path)
      on_exit(fn -> System.put_env("PATH", old_path) end)
      :ok
    end

    test "refuses an explicitly requested model the account cannot use" do
      ws = Ash.create!(Workspace, %{name: "argv-free"})
      record_quota!(ws, "free")
      Config.put_active(ws)

      assert {:error, {:model_unavailable, "gpt-5.5", reason}} =
               Codex.default_argv("hi", model: "gpt-5.5")

      assert reason =~ "free"
    end

    test "passes a tier's substituted model as -m" do
      ws = workspace_with_override!("argv-legacy", @legacy_override)
      record_quota!(ws, "free")
      Config.put_active(ws)

      assert {:ok, argv} = Codex.default_argv("hi", model_tier: "economy")
      assert ["-m", "gpt-5.6-luna"] == Enum.drop_while(argv, &(&1 != "-m")) |> Enum.take(2)
    end
  end

  # ---- helpers -----------------------------------------------------------

  defp write_cache!(home, models, fetched_at \\ DateTime.utc_now()) do
    body = %{
      "fetched_at" => DateTime.to_iso8601(fetched_at),
      "client_version" => "0.153.4",
      "models" =>
        for {slug, vis, prio} <- models do
          %{"slug" => slug, "visibility" => vis, "priority" => prio}
        end
    }

    File.write!(Path.join(home, "models_cache.json"), Jason.encode!(body))
  end

  defp write_auth!(home, mode) do
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"auth_mode" => mode}))
  end

  defp workspace_with_override!(name, tier_models) do
    Ash.create!(Workspace, %{
      name: name,
      config: %{"agent" => %{"config" => %{"codex" => %{"tier_models" => tier_models}}}}
    })
  end

  # Drives the same path the live CloudProbe uses to store `plan: free`.
  defp record_quota!(ws, plan) do
    Req.Test.stub(@quota_stub, fn conn ->
      Req.Test.json(conn, %{
        "plan_type" => plan,
        "rate_limit" => %{"primary_window" => %{"used_percent" => 24.0}}
      })
    end)

    result =
      Arbiter.Quota.Codex.fetch(ws.id, credentials: %{access_token: "t", account_id: "a"})

    assert result.codex.plan == plan
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app_env(key, val), do: Application.put_env(:arbiter, key, val)
end
