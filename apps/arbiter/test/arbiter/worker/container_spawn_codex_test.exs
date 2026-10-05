defmodule Arbiter.Worker.ContainerSpawnCodexTest do
  @moduledoc """
  bd-50d5j6 (P8): Codex under `sandbox.backend: podman`.

  Host-side and argv-level, like `ContainerSpawnTest` (which covers Claude):
  `ContainerSpawn.prepare/1` and `wrap_port/1` with `provider: "codex"` against
  a real private clone and a stand-in egress run. The real-container half is
  `container_spawn_codex_podman_test.exs` (`@moduletag :podman`).
  """
  # async: false: Application env and the shared AuthSync reaper.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.PrivateClone

  @branch "feature/bd-p8-codex"
  @image "localhost/arb-test/codex:1"

  defp auth(refresh, last_refresh) do
    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" => "id",
        "access_token" => "access-" <> refresh,
        "refresh_token" => refresh,
        "account_id" => "acct"
      },
      "last_refresh" => last_refresh
    })
  end

  setup do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, @branch, "main")

    dir = Path.join(ctx.root, "scratch")
    File.mkdir_p!(dir)

    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    # The operator's codex home: a ChatGPT login, a config with a personal
    # profile and their history, none of which may reach the container.
    source_home = Path.join(dir, "operator-codex")
    File.mkdir_p!(source_home)
    File.write!(Path.join(source_home, "auth.json"), auth("rt-0", "2026-10-01T00:00:00Z"))
    File.write!(Path.join(source_home, "config.toml"), ~s(model = "personal"\n))
    File.write!(Path.join(source_home, "state_5.sqlite"), "history")

    # The npm layout: a node launcher script that links to the vendored static
    # binary, which has `rg` and `bwrap` beside it.
    pkg = Path.join(dir, "lib/node_modules/@openai/codex")

    vendor =
      Path.join(pkg, "node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl")

    File.mkdir_p!(Path.join(pkg, "bin"))
    File.mkdir_p!(Path.join(vendor, "bin"))
    File.mkdir_p!(Path.join(vendor, "codex-path"))
    File.mkdir_p!(Path.join(vendor, "codex-resources"))
    File.write!(Path.join(pkg, "bin/codex.js"), "#!/usr/bin/env node\n")
    File.chmod!(Path.join(pkg, "bin/codex.js"), 0o755)
    native = Path.join(vendor, "bin/codex")
    rg = Path.join(vendor, "codex-path/rg")
    bwrap = Path.join(vendor, "codex-resources/bwrap")
    File.write!(native, <<0x7F, "ELF", 0>>)
    File.write!(rg, <<0x7F, "ELF", 0>>)
    File.write!(bwrap, <<0x7F, "ELF", 0>>)
    Enum.each([native, rg, bwrap], &File.chmod!(&1, 0o755))
    File.mkdir_p!(Path.join(dir, "bin"))
    codex_link = Path.join(dir, "bin/codex")
    File.ln_s!("../lib/node_modules/@openai/codex/bin/codex.js", codex_link)

    arb = Path.join(dir, "arb")
    File.write!(arb, "#!/bin/sh\n")

    tmp_dir = Path.join(dir, "run-tmp")
    File.mkdir_p!(tmp_dir)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_container_image: nil
        ] do
      previous = Application.get_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:arbiter, key),
          else: Application.put_env(:arbiter, key, previous)
      end)
    end

    proxy_port = free_port()
    arb_port = free_port()
    test_pid = self()

    egress = fn opts ->
      send(test_pid, {:egress, opts})
      {:ok, [proxy_socket: proxy, proxy_port: proxy_port, bridges: [{arb_port, bridge}]], "rtest"}
    end

    base_opts = [
      provider: "codex",
      policy: podman_policy(),
      worktree_path: clone,
      owner: self(),
      task_id: "bd-p8test",
      arb_token: "arb-secret-token",
      tmp_dir: tmp_dir,
      image: @image,
      podman: "/usr/bin/podman",
      codex_path: codex_link,
      codex_source_home: source_home,
      arb_path: arb,
      egress: egress
    ]

    Map.merge(ctx, %{
      clone: clone,
      dir: dir,
      proxy: proxy,
      source_home: source_home,
      source_auth: Path.join(source_home, "auth.json"),
      native: native,
      rg: rg,
      bwrap: bwrap,
      arb: arb,
      codex_link: codex_link,
      tmp_dir: tmp_dir,
      opts: base_opts
    })
  end

  defp podman_policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})
  end

  defp port_args(ctx, request, env \\ []) do
    %{
      exec: "/bin/sh",
      argv: [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        ContainerSpawn.provider_path("codex"),
        "exec",
        "the prompt"
      ],
      cd: ctx.clone,
      env: ContainerSpawn.apply_env(env, request),
      sandbox: request
    }
  end

  defp mounts(argv), do: for(["-v", spec] <- Enum.chunk_every(argv, 2, 1), do: spec)

  describe "prepare/1 for codex" do
    test "mounts the native binary (not the node launcher), rg, bwrap and arb", ctx do
      assert {:ok, request} = ContainerSpawn.prepare(ctx.opts)

      assert {ctx.native, "/opt/arbiter/cli/codex"} in request.cli_mounts
      assert {ctx.rg, "/opt/arbiter/cli/rg"} in request.cli_mounts
      assert {ctx.bwrap, "/opt/arbiter/cli/bwrap"} in request.cli_mounts
      assert {ctx.arb, "/opt/arbiter/cli/arb"} in request.cli_mounts
      refute Enum.any?(request.cli_mounts, &(elem(&1, 1) == "/opt/arbiter/cli/claude"))
      refute Enum.any?(request.cli_mounts, &String.ends_with?(elem(&1, 0), "codex.js"))
    end

    test "a bare native binary on PATH (no npm tree) is mounted as it is", ctx do
      bare = Path.join(ctx.dir, "bare-codex")
      File.write!(bare, <<0x7F, "ELF", 0>>)
      File.chmod!(bare, 0o755)

      assert {:ok, request} = ContainerSpawn.prepare(Keyword.put(ctx.opts, :codex_path, bare))
      assert {bare, "/opt/arbiter/cli/codex"} in request.cli_mounts
    end

    test "refuses a codex that is a node script with no native binary beside it", ctx do
      lone = Path.join(ctx.dir, "lone/codex.js")
      File.mkdir_p!(Path.dirname(lone))
      File.write!(lone, "#!/usr/bin/env node\n")

      assert {:error, {:codex_native_binary_not_found, ^lone}} =
               ContainerSpawn.prepare(Keyword.put(ctx.opts, :codex_path, lone))
    end

    test "refuses when there is no codex to mount", ctx do
      opts = Keyword.merge(ctx.opts, codex_path: nil, find_executable: fn _ -> nil end)
      assert {:error, {:executable_not_found, "codex"}} = ContainerSpawn.prepare(opts)
    end

    test "gives the run its own CODEX_HOME holding a COPY of auth.json", ctx do
      assert {:ok, request} = ContainerSpawn.prepare(ctx.opts)

      assert request.provider == "codex"
      assert request.config_dir == Path.join(ctx.tmp_dir, "codex-home")
      assert request.home == Path.join(ctx.tmp_dir, "home")

      run_auth = Path.join(request.config_dir, "auth.json")
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(run_auth)
      assert File.read!(run_auth) == File.read!(ctx.source_auth)
      refute run_auth == ctx.source_auth

      # None of the operator's config or history, and no claude config dir.
      refute File.exists?(Path.join(request.config_dir, "state_5.sqlite"))
      refute File.read!(Path.join(request.config_dir, "config.toml")) =~ "personal"
      assert File.regular?(Path.join(request.config_dir, "rules/arbiter.rules"))
      refute File.exists?(Path.join(ctx.tmp_dir, "claude-config"))
    end

    test "starts the egress run with the OpenAI hosts as its infra, not Anthropic's", ctx do
      assert {:ok, _} = ContainerSpawn.prepare(ctx.opts)
      assert_received {:egress, egress_opts}

      infra = Keyword.fetch!(egress_opts, :infra)
      assert "chatgpt.com:443" in infra
      assert "api.openai.com:443" in infra
      refute "api.anthropic.com:443" in infra
    end

    test "a claude prepare still uses the Anthropic infra", ctx do
      claude = Path.join(ctx.dir, "claude")
      File.write!(claude, "#!/bin/sh\n")

      opts = Keyword.merge(ctx.opts, provider: "claude", claude_path: claude)
      assert {:ok, request} = ContainerSpawn.prepare(opts)
      assert_received {:egress, egress_opts}
      assert "api.anthropic.com:443" in Keyword.fetch!(egress_opts, :infra)
      assert request.config_dir == Path.join(ctx.tmp_dir, "claude-config")
    end
  end

  describe "apply_env/2" do
    test "points CODEX_HOME at the run's home, replacing any other", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)

      env = ContainerSpawn.apply_env([{"CODEX_HOME", "/operators/home"}, {"X", "1"}], request)

      assert {"CODEX_HOME", request.config_dir} in env
      assert Enum.count(env, &(elem(&1, 0) == "CODEX_HOME")) == 1
      assert {"X", "1"} in env
      refute Enum.any?(env, &(elem(&1, 0) == "CLAUDE_CONFIG_DIR"))
    end
  end

  describe "wrap_port/1 for codex" do
    test "the real auth.json (and the operator's home) is never bind-mounted", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      assert {:ok, %{argv: argv}} = ContainerSpawn.wrap_port(port_args(ctx, request))

      specs = mounts(argv)
      refute Enum.any?(specs, &String.contains?(&1, ctx.source_home))
      refute Enum.any?(argv, &String.contains?(&1, ctx.source_home))

      # The run's home arrives through the run temp dir, and CODEX_HOME names it.
      assert "#{ctx.tmp_dir}:#{ctx.tmp_dir}:rw" in specs
      assert has_inherit?(argv, "CODEX_HOME")
      assert "--network=none" in argv
      assert "label=disable" in argv
    end

    test "the codex CLI mounts are read-only at the PATH dir", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      assert {:ok, %{argv: argv}} = ContainerSpawn.wrap_port(port_args(ctx, request))

      assert "#{ctx.native}:/opt/arbiter/cli/codex:ro" in mounts(argv)
      assert "#{ctx.rg}:/opt/arbiter/cli/rg:ro" in mounts(argv)
      assert "#{ctx.bwrap}:/opt/arbiter/cli/bwrap:ro" in mounts(argv)
    end

    test "tokens travel as -e NAME with the value in the client env, never on argv", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)

      env = [{"ARBITER_MCP_TOKEN", "mcp-secret"}, {"OPENAI_API_KEY", "sk-secret"}]
      assert {:ok, wrapped} = ContainerSpawn.wrap_port(port_args(ctx, request, env))

      assert has_inherit?(wrapped.argv, "ARBITER_MCP_TOKEN")
      assert has_inherit?(wrapped.argv, "OPENAI_API_KEY")
      assert {"ARBITER_MCP_TOKEN", "mcp-secret"} in wrapped.env
      refute Enum.any?(wrapped.argv, &String.contains?(&1, "mcp-secret"))
      refute Enum.any?(wrapped.argv, &String.contains?(&1, "sk-secret"))
    end

    test "ARB_HOST and the proxy are set, so the -c MCP url and arb work unchanged", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      env = Map.new(request.env)
      assert env["ARB_HOST"] =~ ~r{^http://127\.0\.0\.1:\d+$}
      assert env["HTTPS_PROXY"] =~ ~r{^http://127\.0\.0\.1:\d+$}
    end
  end

  describe "refresh-token rotation (AC2)" do
    defp rotate(request, refresh, last_refresh),
      do: File.write!(Path.join(request.config_dir, "auth.json"), auth(refresh, last_refresh))

    defp source_token(ctx),
      do:
        ctx.source_auth |> File.read!() |> Jason.decode!() |> get_in(["tokens", "refresh_token"])

    test "teardown/1 persists a token the CLI rotated into the real login", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      rotate(request, "rt-1", "2026-10-02T00:00:00Z")
      assert source_token(ctx) == "rt-0"

      assert :ok = ContainerSpawn.teardown(%{sandbox: request})

      assert source_token(ctx) == "rt-1"
    end

    test "re-opening the port (nudge, auto-resume) persists it too", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      rotate(request, "rt-1", "2026-10-02T00:00:00Z")

      assert {:ok, _} = ContainerSpawn.wrap_port(port_args(ctx, request))

      assert source_token(ctx) == "rt-1"
    end

    test "a re-opened run picks up a token a sibling run rotated meanwhile", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      File.write!(ctx.source_auth, auth("rt-9", "2026-10-09T00:00:00Z"))

      assert {:ok, _} = ContainerSpawn.wrap_port(port_args(ctx, request))

      run = request.config_dir |> Path.join("auth.json") |> File.read!() |> Jason.decode!()
      assert run["tokens"]["refresh_token"] == "rt-9"
    end

    test "an older rotation never overwrites a newer login", ctx do
      {:ok, request} = ContainerSpawn.prepare(ctx.opts)
      File.write!(ctx.source_auth, auth("rt-9", "2026-10-09T00:00:00Z"))
      rotate(request, "rt-1", "2026-10-02T00:00:00Z")

      assert :ok = ContainerSpawn.teardown(%{sandbox: request})

      assert source_token(ctx) == "rt-9"
    end

    test "the owning worker dying (no teardown at all) still persists it", ctx do
      owner = spawn(fn -> receive do: (:never -> :ok) end)
      opts = Keyword.put(ctx.opts, :owner, owner)
      {:ok, request} = ContainerSpawn.prepare(opts)
      rotate(request, "rt-1", "2026-10-02T00:00:00Z")

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
      _ = :sys.get_state(Arbiter.Agents.Codex.AuthSync.Reaper)

      assert source_token(ctx) == "rt-1"
    end

    test "the run-tmp reaper flushes the rotation before it deletes the run dir", ctx do
      owner = spawn(fn -> receive do: (:never -> :ok) end)
      {:ok, request} = ContainerSpawn.prepare(Keyword.put(ctx.opts, :owner, owner))
      rotate(request, "rt-1", "2026-10-02T00:00:00Z")

      # The run-tmp reaper owns (and deletes) the dir the copy lives in.
      previous = Application.get_env(:arbiter, :worker_tmp_root)
      Application.put_env(:arbiter, :worker_tmp_root, ctx.dir)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :worker_tmp_root, previous),
          else: Application.delete_env(:arbiter, :worker_tmp_root)
      end)

      :ok = Arbiter.Worker.RunTmp.Reaper.track(owner, ctx.tmp_dir)
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
      _ = :sys.get_state(Arbiter.Worker.RunTmp.Reaper)
      _ = :sys.get_state(Arbiter.Agents.Codex.AuthSync.Reaper)

      refute File.exists?(ctx.tmp_dir)
      assert source_token(ctx) == "rt-1"
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp has_inherit?(argv, name),
    do: Enum.chunk_every(argv, 2, 1) |> Enum.any?(&(&1 == ["-e", name]))
end
