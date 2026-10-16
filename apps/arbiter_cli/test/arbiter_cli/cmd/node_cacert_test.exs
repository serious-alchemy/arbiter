defmodule ArbiterCli.Cmd.NodeCacertTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.Node

  defp serve(listen) do
    case :ssl.transport_accept(listen) do
      {:ok, t} ->
        with {:ok, s} <- :ssl.handshake(t, 5_000),
             {:ok, _} <- :ssl.recv(s, 0, 5_000) do
          :ssl.send(
            s,
            "HTTP/1.1 200 OK\r\ncontent-type: application/yaml\r\ncontent-length: 5\r\nconnection: close\r\n\r\nmode:"
          )

          :ssl.close(s)
        end

        serve(listen)

      _ ->
        :ok
    end
  end

  # A real TLS listener whose chain is signed by a throwaway private CA.
  defp start_tls_server do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [digest: :sha256],
          peer: [digest: :sha256]
        },
        client_chain: %{
          root: [digest: :sha256],
          peer: [digest: :sha256]
        }
      })

    [{:cacerts, [ca | _]} | _] = Enum.filter(client, &match?({:cacerts, _}, &1))

    {:ok, listen} =
      :ssl.listen(
        0,
        [:binary, active: false, reuseaddr: true, versions: [:"tlsv1.2"]] ++
          Keyword.take(server, [:cert, :key])
      )

    {:ok, {_, port}} = :ssl.sockname(listen)

    spawn(fn -> serve(listen) end)
    on_exit(fn -> :ssl.close(listen) end)

    dir = Path.join(System.tmp_dir!(), "arb-cacert-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    pem = Path.join(dir, "ca.pem")
    File.write!(pem, :public_key.pem_encode([{:Certificate, ca, :not_encrypted}]))
    on_exit(fn -> File.rm_rf(dir) end)
    {"https://localhost:#{port}/values.yaml", pem}
  end

  setup do
    Process.delete(:bd2_req_options)
    :ok
  end

  test "a private-CA chain is unknown_ca without --cacert and fetched with it" do
    {url, pem} = start_tls_server()

    # pkix_test_data names the leaf after the machine (its FQDN, not what gethostname returns),
    # so skip only the hostname match; the CA chain is still verified.
    any_host = [customize_hostname_check: [match_fun: fn _, _ -> true end]]
    host_opts = [transport_opts: any_host]

    assert {:error, {:tls_alert, {:unknown_ca, _}}} =
             ArbiterCli.Client.probe_url(url,
               decode_body: false,
               connect_options: host_opts
             )

    [connect_options: [transport_opts: ca_trust]] = Node.__fetch_opts__(pem)
    ca_opts = [transport_opts: any_host ++ ca_trust]

    assert {:ok, "mode:"} =
             ArbiterCli.Client.probe_url(url,
               decode_body: false,
               connect_options: ca_opts
             )
  end
end
