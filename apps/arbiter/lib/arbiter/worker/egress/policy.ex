defmodule Arbiter.Worker.Egress.Policy do
  @moduledoc """
  The egress allow/deny decision for one `CONNECT host:port` (bd-aspkyr,
  `docs/design/guardrail-profiles.md` §4.4). Pure: no I/O, no process state.

  ## Matching

  Exact `host:port`, hosts compared lower-case with any trailing dot dropped.
  A port is always explicit; there is no port wildcard. Entries come from two
  places with different trust:

    * **baseline**, written by the operator (workspace/repo config). May use a
      leading `*.` over at least two labels (`*.hex.pm:443`), which matches
      any subdomain depth but not the apex. See `normalize_baseline/1`.
    * **ticket grants**, the ticket's `network:` entries. Never a wildcard:
      `*.googleapis.com` would include signed-URL uploads to Cloud Storage.
      `normalize_grant/1` refuses one, and `decide/3` matches a wildcard
      grant that reaches it anyway against nothing.

  ## The hard deny

  Hosts under `:no_public_upload` (`SecurityPolicy.egress_deny_hosts/0`, and
  their subdomains) are denied before baseline or grants are consulted, so a
  grant or a wildcard baseline cannot open them. Only a workspace
  `safe_defaults_exclude` containing `:no_public_upload` lifts it, the same
  rule the permission layer follows.

  ## Decision shape

  `{:allow, :baseline | :grant}` or
  `{:deny, :public_upload | :not_granted | :invalid_target}`.
  """

  alias Arbiter.Agents.SecurityPolicy

  @type entry :: {:exact, String.t(), 1..65_535} | {:suffix, String.t(), 1..65_535}
  @type context :: %{
          required(:baseline) => [entry()],
          required(:grants) => [String.t()],
          required(:safe_defaults_exclude) => [atom()]
        }
  @type decision ::
          {:allow, :baseline | :grant}
          | {:deny, :public_upload | :not_granted | :invalid_target}

  @label ~r/\A[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\z/

  @doc "Decides one CONNECT target against `context`."
  @spec decide(String.t(), integer(), context()) :: decision()
  def decide(host, port, %{baseline: baseline, grants: grants} = context) do
    case normalize_target(host, port) do
      {:ok, {h, p}} ->
        cond do
          public_upload?(h) and :no_public_upload not in context.safe_defaults_exclude ->
            {:deny, :public_upload}

          Enum.any?(baseline, &matches?(&1, h, p)) ->
            {:allow, :baseline}

          Enum.any?(grants, &grant_matches?(&1, h, p)) ->
            {:allow, :grant}

          true ->
            {:deny, :not_granted}
        end

      :error ->
        {:deny, :invalid_target}
    end
  end

  @doc """
  Normalizes an operator-written baseline. Wildcards are accepted here.
  Returns the first offending entry on error: a bad baseline is a config bug
  and must not be silently dropped.
  """
  @spec normalize_baseline([String.t()]) ::
          {:ok, [entry()]} | {:error, {:invalid_baseline, term()}}
  def normalize_baseline(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_entry(raw, true) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} -> {:halt, {:error, {:invalid_baseline, raw}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @doc """
  Normalizes one ticket grant (`"host:port"` or `"network:host:port"`) to its
  canonical `"host:port"`. Refuses wildcards and a missing port.
  """
  @spec normalize_grant(String.t()) ::
          {:ok, String.t()} | {:error, :wildcard_not_allowed | :missing_port | :invalid}
  def normalize_grant(raw) when is_binary(raw) do
    raw = String.replace_prefix(raw, "network:", "")

    if String.contains?(raw, "*") do
      {:error, :wildcard_not_allowed}
    else
      with {:ok, {:exact, h, p}} <- parse_entry(raw, false), do: {:ok, format(h, p)}
    end
  end

  def normalize_grant(_), do: {:error, :invalid}

  @doc """
  Splits an `authority` (`host:port`, `[v6]:port`) into a normalized
  `{host, port}`. The port is required.
  """
  @spec parse_authority(String.t()) ::
          {:ok, {String.t(), 1..65_535}} | {:error, :missing_port | :invalid}
  def parse_authority(authority) when is_binary(authority) do
    case split_authority(authority) do
      {:ok, host, port_str} ->
        with {port, ""} when port in 1..65_535 <- Integer.parse(port_str),
             {:ok, h} <- normalize_host(host) do
          {:ok, {h, port}}
        else
          _ -> {:error, :invalid}
        end

      :no_port ->
        {:error, :missing_port}

      :error ->
        {:error, :invalid}
    end
  end

  def parse_authority(_), do: {:error, :invalid}

  @doc "The canonical `host:port` string for an event row or log line."
  @spec format(String.t(), integer()) :: String.t()
  def format(host, port) do
    if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  # --- internals ---------------------------------------------------------

  defp public_upload?(host) do
    Enum.any?(SecurityPolicy.egress_deny_hosts(), fn denied ->
      host == denied or String.ends_with?(host, "." <> denied)
    end)
  end

  defp matches?({:exact, host, port}, host, port), do: true
  defp matches?({:suffix, suffix, port}, host, port), do: String.ends_with?(host, suffix)
  defp matches?(_, _, _), do: false

  # Grants are stored raw (the ticket's permission strings) and normalized
  # per decision, so a malformed or wildcard entry just matches nothing.
  defp grant_matches?(raw, host, port) do
    case normalize_grant(raw) do
      {:ok, canonical} -> canonical == format(host, port)
      _ -> false
    end
  end

  defp normalize_target(host, port)
       when is_binary(host) and is_integer(port) and port in 1..65_535 do
    case normalize_host(host) do
      {:ok, h} -> {:ok, {h, port}}
      :error -> :error
    end
  end

  defp normalize_target(_, _), do: :error

  defp parse_entry(raw, allow_wildcard?) when is_binary(raw) do
    with {:ok, host, port_str} <- split_entry(raw),
         {port, ""} when port in 1..65_535 <- Integer.parse(port_str) do
      case host do
        "*." <> rest when allow_wildcard? ->
          with {:ok, h} <- normalize_host(rest),
               true <- length(String.split(h, ".")) >= 2 and not ip?(h) do
            {:ok, {:suffix, "." <> h, port}}
          else
            _ -> {:error, :invalid}
          end

        _ ->
          case normalize_host(host) do
            {:ok, h} -> {:ok, {:exact, h, port}}
            :error -> {:error, :invalid}
          end
      end
    else
      :no_port -> {:error, :missing_port}
      _ -> {:error, :invalid}
    end
  end

  defp parse_entry(_, _), do: {:error, :invalid}

  defp split_entry(raw), do: raw |> String.trim() |> split_authority()

  defp split_authority("[" <> rest) do
    case String.split(rest, "]:", parts: 2) do
      [host, port] -> {:ok, host, port}
      _ -> :error
    end
  end

  defp split_authority(authority) do
    case String.split(authority, ":") do
      [host, port] -> {:ok, host, port}
      [_host] -> :no_port
      _ -> :error
    end
  end

  defp normalize_host(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, ip |> :inet.ntoa() |> to_string()}

      {:error, _} ->
        labels = String.split(host, ".")

        if host != "" and byte_size(host) <= 253 and Enum.all?(labels, &Regex.match?(@label, &1)),
          do: {:ok, host},
          else: :error
    end
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
end
