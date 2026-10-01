defmodule ArbiterCli.FakeOperatorSocket do
  @moduledoc """
  A stand-in for the server's `Arbiter.MCP.OperatorSocket` (bd-8381tk) in CLI
  tests: a real Unix socket that answers each connection with `response` and
  forwards the decoded request to the test process as
  `{:operator_request, map}`. Points the CLI at it through the
  `:bd2_operator_socket` process-dict hook, so tests stay async-safe.
  """

  import ExUnit.Callbacks

  @doc "Start the fake. Returns its socket path."
  def start!(response) do
    dir =
      Path.join(System.tmp_dir!(), "fops-#{System.pid()}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "op.sock")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: :line, active: false])

    owner = self()
    start_supervised!({Task, fn -> loop(lsock, owner, response) end}, id: {__MODULE__, path})
    Process.put(:bd2_operator_socket, path)
    path
  end

  defp loop(lsock, owner, response) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    request = Jason.decode!(line)
    send(owner, {:operator_request, request})
    :ok = :gen_tcp.send(sock, [Jason.encode!(response), "\n"])
    :gen_tcp.close(sock)
    loop(lsock, owner, response)
  end
end
