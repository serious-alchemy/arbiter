defmodule Arbiter.Worker.ContainerSpawnCodexPodmanTest do
  @moduledoc """
  bd-50d5j6 (P8): Codex under `sandbox.backend: podman`, against a REAL rootless
  podman and the host's real `codex`.

  Opt-in, because it starts containers:

      cd apps/arbiter && mix test --include podman \\
        test/arbiter/worker/container_spawn_codex_podman_test.exs

  The `:live_codex` test additionally runs one real `codex exec` turn with the
  operator's ChatGPT login (a few tokens; the login may rotate, which is the
  point of `AuthSync`):

      cd apps/arbiter && ARB_LIVE_IMAGE=<tag> ARB_LIVE_CODEX=1 mix test --include podman --include live_codex \\
        test/arbiter/worker/container_spawn_codex_podman_test.exs

  `ARB_LIVE_CODEX_HOME` overrides the login's home (default `~/.codex`).
  `ARB_LIVE_IMAGE` names a local image with `sh`, `socat` and `git` (the worker
  images Arbiter builds qualify). Every container is named `arb-…` and removed
  by that exact name.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Test.GitFixture
  alias Arbiter.Test.StubMcpServer
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Egress.Event
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.PrivateClone

  @moduletag :podman
  @moduletag timeout: 600_000

  setup tags do
    image = System.get_env("ARB_LIVE_IMAGE")
    live? = System.get_env("ARB_LIVE_CODEX") == "1"
    source_home = System.get_env("ARB_LIVE_CODEX_HOME") || Path.expand("~/.codex")
    source_auth = Path.join(source_home, "auth.json")

    cond do
      image in [nil, ""] ->
        {:ok, skip: "set ARB_LIVE_IMAGE to a local worker image"}

      tags[:live_codex] && !live? ->
        {:ok, skip: "set ARB_LIVE_CODEX=1 to spend a real turn"}

      not File.regular?(source_auth) ->
        {:ok, skip: "no ChatGPT login at #{source_auth}"}

      true ->
        {:ok,
         Map.merge(fixture(image), %{
           source_home: source_home,
           source_auth: source_auth,
           skip: nil
         })}
    end
  end

  defp fixture(image) do
    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, "feature/bd-p8-live", "main")
    tmp_dir = Path.join(ctx.root, "run-tmp")
    File.mkdir_p!(tmp_dir)
    {:ok, mcp} = StubMcpServer.start(self())
    on_exit(fn -> StubMcpServer.stop(mcp) end)

    prior = Application.get_env(:arbiter, Arbiter.MCP)
    url = "http://127.0.0.1:#{mcp.port}/mcp"

    Application.put_env(
      :arbiter,
      Arbiter.MCP,
      Keyword.merge(prior || [], url: url, inject_config: true)
    )

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true
        ] do
      previous = Application.get_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:arbiter, key),
          else: Application.put_env(:arbiter, key, previous)
      end)
    end

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, Arbiter.MCP, prior),
        else: Application.delete_env(:arbiter, Arbiter.MCP)
    end)

    %{clone: clone, tmp_dir: tmp_dir, image: image, mcp: mcp, mcp_url: url}
  end

  defp policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})
  end

  defp prepare!(ctx) do
    {:ok, request} =
      ContainerSpawn.prepare(
        provider: "codex",
        policy: policy(),
        worktree_path: ctx.clone,
        owner: self(),
        task_id: "bd-p8live",
        arb_token: "live-arb-token",
        tmp_dir: ctx.tmp_dir,
        codex_source_home: ctx.source_home,
        image: ctx.image,
        deps_cache: false,
        services: [],
        egress: fn opts -> JailRun.start([arbiter_url: ctx.mcp_url] ++ opts) end
      )

    on_exit(fn -> ContainerSpawn.teardown(%{sandbox: request}) end)
    request
  end

  # Run `argv` (an inner command) the way `ClaudeSession` would: the `podman run`
  # `wrap_port/1` builds, with the secrets in the client's environment.
  defp run_wrapped(ctx, request, argv, env \\ []) do
    port_args = %{
      exec: "/bin/sh",
      argv: argv,
      cd: ctx.clone,
      env: ContainerSpawn.apply_env(env, request),
      sandbox: request
    }

    {:ok, wrapped} = ContainerSpawn.wrap_port(port_args)
    [_ | args] = wrapped.argv

    task =
      Task.async(fn ->
        System.cmd(wrapped.exec, args, env: wrapped.env, stderr_to_stdout: true)
      end)

    case Task.yield(task, 480_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("container run timed out")
    end
  end

  test "the container sees its own copy of the login and not the operator's home", ctx do
    if ctx.skip, do: flunk("skipped: #{ctx.skip}")
    request = prepare!(ctx)

    {out, 0} =
      run_wrapped(ctx, request, [
        "sh",
        "-c",
        ~s(exec "$@" < /dev/null),
        "sh",
        "sh",
        "-c",
        ~s(echo "CODEX_HOME=$CODEX_HOME"; ls "$CODEX_HOME"; codex login status 2>&1; ) <>
          ~s(echo "mounts:"; grep -c "#{ctx.source_home}" /proc/self/mountinfo || true)
      ])

    assert out =~ "CODEX_HOME=#{request.config_dir}"
    assert out =~ "auth.json"
    assert out =~ "Logged in using ChatGPT"
    # The operator's home is not mounted: nothing in mountinfo names it.
    assert String.ends_with?(String.trim(out), "0")
  end

  @tag :live_codex
  test "a real codex turn: per-run CODEX_HOME, MCP over -c and the bridge, egress via the proxy",
       ctx do
    if ctx.skip, do: flunk("skipped: #{ctx.skip}")
    before = File.read!(ctx.source_auth)
    request = prepare!(ctx)

    prompt =
      "Call the `ping` tool of the MCP server named arbiter exactly once, with no arguments. " <>
        "Then reply with the single word DONE and nothing else."

    {:ok, argv} =
      Codex.default_argv(prompt,
        security: policy(),
        sandbox_wrap: true,
        arb_token: "live-arb-token",
        worktree_path: ctx.clone
      )

    env =
      Codex.spawn_env(
        security: policy(),
        sandbox_wrap: true,
        arb_token: "live-arb-token",
        worktree_path: ctx.clone
      )
      |> Enum.reject(&(elem(&1, 0) == "OPENAI_API_KEY"))

    {out, status} = run_wrapped(ctx, request, argv, env)
    IO.puts("\n--- codex exec (in container) exit #{status} ---\n#{out}\n---")

    # MCP: reached over the Arbiter bridge from the `-c` overrides, with the
    # bearer. The CLI connects its MCP servers at startup, before any model turn.
    assert_receive {:mcp_request, %{rpc: "initialize", authorization: "Bearer live-arb-token"}},
                   5_000

    assert_receive {:mcp_request, %{rpc: "tools/list", authorization: "Bearer live-arb-token"}},
                   5_000

    # The model turn needs quota. An account that is out of it still proves the
    # login and the egress (the API answered through the proxy); a turn that ran
    # must have called the tool.
    if status == 0 do
      assert out =~ "DONE"

      assert_receive {:mcp_request, %{rpc: "tools/call", authorization: "Bearer live-arb-token"}},
                     5_000
    else
      IO.puts("model turn refused (exit #{status}); tools/call not exercised")
      assert out =~ "usage limit"
    end

    # Egress: everything the model API needed went through the proxy.
    hosts = Event |> Ash.read!() |> Enum.map(& &1.host) |> Enum.uniq()
    IO.puts("egress hosts seen by the proxy: #{inspect(hosts)}")
    assert Enum.any?(hosts, &String.contains?(&1, "chatgpt.com"))

    # Auth: the real file was never mounted, and whatever the CLI did to its copy
    # is now in the real one (unchanged when no refresh was due).
    ContainerSpawn.teardown(%{sandbox: request})
    after_ = File.read!(ctx.source_auth)
    run_copy = File.read!(Path.join(request.config_dir, "auth.json"))
    assert after_ == run_copy or after_ == before
    IO.puts("auth.json rotated during the run: #{after_ != before}")
  end
end
