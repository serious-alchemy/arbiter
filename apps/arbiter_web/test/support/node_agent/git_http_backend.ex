defmodule ArbiterWeb.GitHttpBackend do
  @moduledoc """
  A Plug that serves the repositories under `:root` over git's smart HTTP protocol by
  running the host's real `git http-backend` as a CGI, for the `:node_agent` suite: it
  is the forge a container pushes to over the egress bridge.

  `init/1` takes `root: dir`. Every repo under it is exported and accepts pushes.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :root)

  @impl Plug
  def call(conn, root) do
    {:ok, body, conn} = read_body(conn, length: 64_000_000)

    env =
      [
        {"GIT_PROJECT_ROOT", root},
        {"GIT_HTTP_EXPORT_ALL", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"REQUEST_METHOD", conn.method},
        {"PATH_INFO", conn.request_path},
        {"QUERY_STRING", conn.query_string},
        {"CONTENT_TYPE", header(conn, "content-type")},
        {"CONTENT_LENGTH", Integer.to_string(byte_size(body))},
        {"HTTP_CONTENT_ENCODING", header(conn, "content-encoding")},
        {"REMOTE_USER", "e2e"},
        {"REMOTE_ADDR", "127.0.0.1"}
      ]
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    backend = Path.join(String.trim(git_exec_path()), "git-http-backend")

    port =
      Port.open({:spawn_executable, backend}, [:binary, :exit_status, :use_stdio, env: env])

    Port.command(port, body)
    {head, payload} = split_cgi(collect(port, ""))

    {status, headers} = parse_headers(head)

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    send_resp(conn, status, payload)
  end

  defp header(conn, name), do: List.first(get_req_header(conn, name)) || ""

  defp git_exec_path do
    {out, 0} = System.cmd("git", ["--exec-path"])
    out
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      30_000 -> raise "git http-backend did not exit"
    end
  end

  defp split_cgi(output) do
    case :binary.split(output, ["\r\n\r\n", "\n\n"]) do
      [head, payload] -> {head, payload}
      [head] -> {head, ""}
    end
  end

  defp parse_headers(head) do
    pairs =
      for line <- String.split(head, ~r/\r?\n/, trim: true),
          [k, v] <- [String.split(line, ":", parts: 2)],
          do: {String.downcase(k), String.trim(v)}

    status =
      case List.keyfind(pairs, "status", 0) do
        {_, value} -> value |> String.split(" ") |> hd() |> String.to_integer()
        nil -> 200
      end

    {status, List.keydelete(pairs, "status", 0)}
  end
end
