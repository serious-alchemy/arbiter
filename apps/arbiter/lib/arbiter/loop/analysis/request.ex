defmodule Arbiter.Loop.Analysis.Request do
  @moduledoc """
  Turn a surface's analysis params (REST query/JSON body, MCP tool args — both
  string-keyed) into the keyword options `Arbiter.Loop.Analysis.analyze/1`
  takes (P-23).

  One parser, so `POST /api/loop/analyze`, `POST /api/loop/propose`,
  `loop_analyze` and `loop_propose` accept the same `since` / `until` /
  `limit` / `label` / `discover` and refuse the same malformed values. Each
  adapter only maps the `{:error, message}` onto its own error shape.

  `limit` is clamped to `max_limit/0` (never refused for being too big). A
  surface that must never scan unbounded (MCP) passes `default_limit:` so an
  omitted `limit` still carries the cap, as `memory_distill`'s caps do; REST
  keeps "no cap requested" as nil.
  """

  alias Arbiter.Params

  @max_limit 500

  @doc "The documented ceiling on runs scanned per pass."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Options for `Analysis.analyze/1`, minus `:propose?` and `:workspace_id`
  (the caller owns those). `{:error, message}` on the first bad value.

  Options: `:default_limit` — the limit used when none is supplied.
  """
  @spec build(map(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def build(params, opts \\ []) when is_map(params) do
    with {:ok, since} <- parse_window(params["since"]),
         {:ok, until} <- parse_iso(params["until"]),
         {:ok, limit} <- parse_limit(params["limit"], Keyword.get(opts, :default_limit)),
         {:ok, discover?} <- parse_discover(params["discover"]) do
      {:ok,
       [discover?: discover?]
       |> put(:since, since)
       |> put(:until, until)
       |> put(:limit, limit)
       |> put(:label, blank_to_nil(params["label"]))}
    end
  end

  # Accepts relative shortcuts (7d / 24h / 30m) or absolute ISO8601.
  defp parse_window(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_window(raw) when is_binary(raw) do
    case Regex.run(~r/^(\d+)([dhm])$/, raw) do
      [_, n, unit] ->
        {:ok, DateTime.add(DateTime.utc_now(), -String.to_integer(n) * unit_seconds(unit), :second)}

      nil ->
        parse_iso(raw)
    end
  end

  defp parse_window(other), do: parse_iso(other)

  defp parse_iso(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_iso(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> {:error, "expected ISO8601 or a 7d/24h/30m shortcut, got #{inspect(raw)}"}
    end
  end

  defp parse_iso(other),
    do: {:error, "expected ISO8601 or a 7d/24h/30m shortcut, got #{inspect(other)}"}

  # A string on the GET query / REST alias, a real integer in a JSON body or an
  # MCP argument; anything else is refused rather than crashing.
  defp parse_limit(raw, default) when raw in [nil, ""] and is_nil(default), do: {:ok, nil}
  defp parse_limit(raw, default), do: raw |> Params.limit(default || @max_limit, @max_limit) |> unwrap()

  defp unwrap({:error, {:invalid, msg}}), do: {:error, msg}
  defp unwrap(ok), do: ok

  # bd-4f6opo: the opt-in model pass. Unrecognised is refused, never a silent "off".
  defp parse_discover(v) when v in [nil, ""], do: {:ok, false}

  defp parse_discover(v) do
    case Params.boolean(v) do
      {:ok, b} -> {:ok, b}
      :error -> {:error, "discover must be true or false"}
    end
  end

  defp unit_seconds("d"), do: 24 * 3600
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("m"), do: 60

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
