defmodule Arbiter.Agents.Qwen.ConfigDirEgressTest do
  # Drives the REAL qwen CLI with `Qwen.ConfigDir`'s env against the scripted
  # fixture server, with a recording proxy as HTTPS_PROXY/HTTP_PROXY. The
  # fixture server is on 127.0.0.1 (NO_PROXY), so any proxied request is egress
  # to somewhere else. Excluded unless `qwen` is on PATH (test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :qwen_cli
  @moduletag :tmp_dir
  @moduletag :capture_log

  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.Test.{QwenCli, ScriptedOpenAI}

  @forbidden ~w(models.dev rum telemetry sentry aliyuncs.com alibabacloud.com)

  setup %{tmp_dir: dir} do
    prev = Application.get_env(:arbiter, :worker_qwen_home_root)
    Application.put_env(:arbiter, :worker_qwen_home_root, Path.join(dir, "homes"))

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :worker_qwen_home_root, prev),
        else: Application.delete_env(:arbiter, :worker_qwen_home_root)
    end)
  end

  test "no models.dev or telemetry/RUM egress with ConfigDir's env", %{tmp_dir: dir} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    {:ok, seen} = Agent.start_link(fn -> [] end)
    acceptor = spawn_link(fn -> accept(listener, seen) end)

    server = ScriptedOpenAI.start_supervised!([{:text, "scripted-pong"}])
    {:ok, config_env} = ConfigDir.env(worktree: dir)
    proxy = "http://127.0.0.1:#{port}"

    env =
      for({k, v} <- config_env, is_binary(v), do: {k, v}) ++
        [
          {"OPENAI_BASE_URL", server.url},
          {"OPENAI_API_KEY", "test-key"},
          {"OPENAI_MODEL", "scripted-model"},
          {"HTTPS_PROXY", proxy},
          {"HTTP_PROXY", proxy},
          {"https_proxy", proxy},
          {"http_proxy", proxy},
          {"NO_PROXY", "127.0.0.1,localhost"},
          {"no_proxy", "127.0.0.1,localhost"}
        ]

    unset = for {k, false} <- config_env, do: {k, nil}

    {out, status} =
      System.cmd(
        QwenCli.executable(),
        ["--auth-type", "openai", "--yolo", "--bare", "-p", "say pong"],
        cd: dir,
        env: env ++ unset,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "scripted-pong"

    Process.exit(acceptor, :normal)
    :gen_tcp.close(listener)
    requests = Agent.get(seen, & &1)

    for line <- requests, word <- @forbidden do
      refute String.contains?(String.downcase(line), word),
             "qwen reached #{inspect(line)} via the proxy"
    end

    # Anything at all through the proxy is egress the config should have shut off.
    assert requests == [], "unexpected proxied requests: #{inspect(requests)}"
  end

  defp accept(listener, seen) do
    case :gen_tcp.accept(listener) do
      {:ok, sock} ->
        case :gen_tcp.recv(sock, 0, 2_000) do
          {:ok, data} -> Agent.update(seen, &[hd(String.split(data, "\r\n")) | &1])
          _ -> :ok
        end

        :gen_tcp.send(sock, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(sock)
        accept(listener, seen)

      _ ->
        :ok
    end
  end
end
