defmodule Arbiter.Agents.Qwen.Egress do
  @moduledoc """
  The network side of a jailed qwen spawn (bd-az8ycn, Q5 of bd-3km00p): what
  `Arbiter.Worker.Egress.JailRun` is given for the endpoint qwen talks to, and
  how a denied connection is recognised afterwards.

  A jailed qwen runs in its own network namespace (`--unshare-net`): the only
  ways out are the run's filtering proxy and the fixed-destination bridges.
  Where the model lives decides which one qwen uses (`plan/2`):

    * **A local endpoint** (Ollama on `127.0.0.1:11434`, a local vLLM) is a
      *tunnel*, `{port, "127.0.0.1", port}`: `127.0.0.1:<port>` inside the jail
      reaches the same port on the host, so the `OPENAI_BASE_URL` the adapter
      already exports works unchanged. qwen's `NO_PROXY` covers loopback, so it
      talks to the bridge directly. The destination is fixed; it is not the
      worker's to choose.
    * **A hosted endpoint** goes through the proxy. Its `host:port` is the whole
      baseline the adapter contributes (`infra`): qwen's phone-home switches are
      off (`Qwen.ConfigDir`), so the model API is the only host it needs. The
      ticket's git remote is added by `JailRun`, and the operator's
      `sandbox.allow_hosts` and the ticket's `network:` grants by `baseline/2`
      and the run's grants.

  Everything else is denied. The proxy runs **enforcing** for qwen
  (`enforce?/0`): a local model with a yolo shell is the least trusted worker we
  run, and the baseline is known exactly. Unlike agy, whose proxy runs in learn
  mode until its baseline is recorded, a qwen `CONNECT` outside the baseline is
  answered `403` and recorded as an `egress_events` row.

  ## Classification

  A denied connection reaches qwen as a proxy `403` on `CONNECT` (a Node
  `Proxy response (403) !== 200 when HTTP Tunneling`, curl's `CONNECT tunnel
  failed, response 403`), or, from a process that ignores the proxy settings,
  as a failure to route at all (`ENETUNREACH`, `EAI_AGAIN`: the namespace has no
  route and no resolver). `denied?/1` recognises those shapes and `stop_reason/2`
  turns them into the `:egress_denied` category, so a run that could not reach
  its endpoint is not filed as a crash or a generic gateway error.

  The signatures are the documented error shapes, not captures from a live qwen
  (none was available, `docs/qwen-test-harness.md`).
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.StopReason

  @loopback_hosts ["127.0.0.1", "localhost", "::1"]

  # The proxy answers a denied CONNECT `403 Forbidden` with
  # `X-Arbiter-Egress: <reason>`. A route-less namespace fails to connect or
  # resolve instead. `ECONNREFUSED` is deliberately absent: it is how a stopped
  # model server looks, and that is not a denial.
  @denied_signature ~r/
      proxy[ ]response[ ]\(403\)
    | received[ ]http[ ]code[ ]403[ ]from[ ]proxy
    | connect[ ]tunnel[ ]failed,[ ]response[ ]403
    | tunnel[ ]connection[ ]failed:[ ]proxy[ ]response[ ]\(403\)
    | x-arbiter-egress:
    | \bENETUNREACH\b
    | network[ ]is[ ]unreachable
    | \bEAI_AGAIN\b
  /ix

  @lan_suffixes ~w(.local .lan .internal .home.arpa)

  @type plan :: %{
          tunnels: [{:inet.port_number(), String.t(), :inet.port_number()}],
          infra: [String.t()],
          allow_local_dial: boolean()
        }

  @doc """
  The tunnels and the proxy baseline for `endpoint` (a map with `:base_url`)
  under `policy`. The policy's own `sandbox.egress_tunnels` are included in the
  tunnels, deduplicated on the local port.
  """
  @spec plan(map() | nil, SecurityPolicy.t()) :: plan()
  def plan(endpoint, %SecurityPolicy{} = policy) do
    {tunnels, infra, lan?} =
      case parse(endpoint) do
        {:local, port} -> {[{port, "127.0.0.1", port}], [], false}
        {:hosted, authority, lan?} -> {[], [authority], lan?}
        :none -> {[], [], false}
      end

    %{
      tunnels: Enum.uniq_by(tunnels ++ SecurityPolicy.egress_tunnels(policy), &elem(&1, 0)),
      infra: infra,
      allow_local_dial: lan?
    }
  end

  @doc """
  The proxy baseline for `plan` under `policy`: the endpoint, plus the operator's
  `allow_hosts` the policy's egress level reaches. `sandbox.egress: :open` means
  "no host filtering" for the adapters that run a learn-mode proxy; a qwen proxy
  enforces, so it is read as `:allowlist` (every `allow_hosts` entry).
  """
  @spec baseline(plan(), SecurityPolicy.t()) :: [String.t()]
  def baseline(%{infra: infra}, %SecurityPolicy{sandbox: sandbox} = policy) do
    filtered =
      case Map.get(sandbox, :egress, :open) do
        :open -> %{policy | sandbox: Map.put(sandbox, :egress, :allowlist)}
        _ -> policy
      end

    SecurityPolicy.egress_baseline(filtered, infra)
  end

  @doc "True when the qwen egress proxy denies (`config :arbiter, :worker_qwen_egress_enforce`, default true)."
  @spec enforce?() :: boolean()
  def enforce?, do: Application.get_env(:arbiter, :worker_qwen_egress_enforce, true) != false

  @doc "True when `text` carries a recognised egress-denial shape."
  @spec denied?(String.t()) :: boolean()
  def denied?(text) when is_binary(text), do: Regex.match?(@denied_signature, text)

  @doc """
  The `:egress_denied` `StopReason` for a haystack that matched `denied?/1`;
  the summary quotes the first matching line.
  """
  @spec stop_reason(integer() | nil, String.t()) :: StopReason.t()
  def stop_reason(exit_status, haystack) when is_binary(haystack) do
    line =
      haystack
      |> String.split("\n")
      |> Enum.find("", &Regex.match?(@denied_signature, &1))
      |> String.trim()
      |> String.slice(0, 200)

    %StopReason{
      category: :egress_denied,
      summary: "qwen's network access was denied by the worker jail: #{line}",
      remediation:
        "The jail only reaches the model endpoint, the ticket's git remote and the " <>
          "workspace's `sandbox.allow_hosts`. If the host is legitimate, add it to " <>
          "`sandbox.allow_hosts` (or give the ticket a `network:` grant); a local endpoint " <>
          "must be a loopback URL (it is tunnelled) or a hosted one the proxy can reach. " <>
          "`egress_events` names the denied host.",
      exit_status: exit_status,
      signal: nil
    }
  end

  # ---- internals ---------------------------------------------------------

  defp parse(%{base_url: url}) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        host = String.downcase(host)

        if loopback?(host),
          do: {:local, port},
          else: {:hosted, "#{host}:#{port}", lan?(host)}

      _ ->
        :none
    end
  end

  defp parse(_endpoint), do: :none

  # A hosted endpoint on a private network: the proxy must be allowed to dial
  # private addresses for it (the baseline still limits it to that host).
  defp lan?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> private_ip?(ip)
      {:error, _} -> not String.contains?(host, ".") or String.ends_with?(host, @lan_suffixes)
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?(_ip), do: false

  defp loopback?(host), do: host in @loopback_hosts or String.starts_with?(host, "127.")
end
