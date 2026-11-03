defmodule Arbiter.NodeAgent.RegistryProbe do
  @moduledoc """
  SI4a (`docs/design/remote-workers.md` §21.4): the agent's readiness `registry` rows. For
  each host the primary names in `hello_ok.registries`, an unauthenticated `GET /v2/` over
  HTTPS (HTTP when TLS fails, for an insecure registry): 200 or 401 means a registry
  answers, so the node is `reachable`; anything else, or no answer, is `unreachable`. The
  agent reports the map in its `hb`; the primary passes over a node that reports a repo's
  registry unreachable. No credential is sent.
  """

  @max_hosts 16
  @timeout_ms 5_000

  @type status :: String.t()

  @doc "`%{host => \"reachable\" | \"unreachable\"}`. Options: `:req_options` (tests)."
  @spec probe([term()], keyword()) :: %{String.t() => status()}
  def probe(hosts, opts \\ []) when is_list(hosts) do
    hosts
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(@max_hosts)
    |> Map.new(&{&1, status(&1, opts)})
  end

  defp status(host, opts) do
    if Enum.any?(["https", "http"], &answers?(&1, host, opts)),
      do: "reachable",
      else: "unreachable"
  end

  defp answers?(scheme, host, opts) do
    req =
      Keyword.merge(
        [
          url: "#{scheme}://#{host}/v2/",
          retry: false,
          redirect: false,
          receive_timeout: @timeout_ms,
          connect_options: [timeout: @timeout_ms]
        ],
        Keyword.get(opts, :req_options, [])
      )

    match?({:ok, %Req.Response{status: s}} when s in [200, 401], Req.get(req))
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
