defmodule Arbiter.Agents.Qwen.Usage do
  @moduledoc """
  Qwen usage for the ledger (bd-1po4s4, Q7 of the bd-3km00p epic): stream
  normalisation, reconcile against the session JSONL, and per-endpoint cost.

  ## Normalise

  qwen speaks the OpenAI usage convention: `input_tokens` **includes** the
  cached part (`total_tokens` is `input + output`). The ledger keeps uncached
  input in `tokens_in` and the cached part in `cache_read_tokens`, so
  `normalize_stream/1` subtracts the cache reads from the stream's input.

  ## Reconcile

  `reconcile/2` merges the stream-derived usage with `Qwen.SessionFile` totals.
  The JSONL is authoritative for the token counts it holds (it is written per
  API response, so it survives a kill and carries thinking tokens); the stream
  fills whatever the JSONL lacks. When both exist and disagree, the drift is
  recorded under `raw["usage_reconcile"]` rather than silently picking a side.

  ## Cost

  qwen reports no cost, so `price/2` computes it from the endpoint the run used
  (`endpoint[:pricing]`, USD per million tokens: `:input`, `:output`,
  `:cache_read`, `:cache_creation`). An `unmetered: true` endpoint (a local
  Ollama/vLLM box) records exactly `0.0`; an endpoint with neither leaves
  `cost_usd` nil, which means "unknown", never free.
  """

  @type usage :: map()

  @doc "Stream-reported usage with the cached part moved out of `tokens_in`."
  @spec normalize_stream(usage()) :: usage()
  def normalize_stream(%{} = usage) do
    case {Map.get(usage, :tokens_in), Map.get(usage, :cache_read_tokens)} do
      {input, cached} when is_integer(input) and is_integer(cached) and cached > 0 ->
        Map.put(usage, :tokens_in, max(input - cached, 0))

      _ ->
        usage
    end
  end

  def normalize_stream(usage), do: usage

  @doc """
  Merge normalised stream usage with the session JSONL totals (`{:ok, totals}`
  from `Qwen.SessionFile`, or `:none`).
  """
  @spec reconcile(usage(), {:ok, map()} | :none) :: usage()
  def reconcile(stream, :none), do: Map.put(stream, :usage_source, :stream)

  def reconcile(stream, {:ok, file}) do
    fields = [:tokens_in, :tokens_out, :cache_read_tokens]
    drift = for f <- fields, d = drift(stream, file, f), into: %{}, do: {Atom.to_string(f), d}

    merged =
      stream
      |> Map.merge(Map.take(file, fields ++ [:thinking_tokens]))
      |> Map.put_new(:model, file.model)
      |> Map.put_new(:session_id, file.session_id)
      |> Map.put(
        :usage_source,
        if(map_size(stream_tokens(stream)) == 0, do: :session_file, else: :reconciled)
      )

    note = %{"api_calls" => file.api_calls, "drift" => drift}
    raw = Map.put(Map.get(merged, :raw) || %{}, "usage_reconcile", note)
    Map.put(merged, :raw, raw)
  end

  defp stream_tokens(stream),
    do: Map.take(stream, [:tokens_in, :tokens_out, :cache_read_tokens])

  # stream-minus-file, only when the stream had a figure and it differs
  defp drift(stream, file, field) do
    from_file = Map.fetch!(file, field)

    case Map.get(stream, field) do
      n when is_integer(n) and n != from_file -> n - from_file
      _ -> nil
    end
  end

  @doc """
  Set `:cost_usd` / `:cost_note` from the endpoint. `endpoint` is the map the
  run was dispatched with (`:unmetered`, `:pricing`); `nil` or unpriced leaves
  cost unknown.
  """
  @spec price(usage(), map() | nil) :: usage()
  def price(usage, %{unmetered: true}),
    do: usage |> Map.put(:cost_usd, 0.0) |> Map.put(:cost_note, "unmetered endpoint")

  def price(usage, %{pricing: %{} = pricing}) do
    rate = fn key -> number(Map.get(pricing, key) || Map.get(pricing, Atom.to_string(key))) end

    cost =
      [
        {:tokens_in, :input},
        {:tokens_out, :output},
        {:thinking_tokens, :output},
        {:cache_read_tokens, :cache_read},
        {:cache_creation_tokens, :cache_creation}
      ]
      |> Enum.reduce(0.0, fn {field, key}, acc ->
        acc + number(Map.get(usage, field)) * rate.(key) / 1_000_000
      end)

    usage |> Map.put(:cost_usd, cost) |> Map.put(:cost_note, "computed from endpoint pricing")
  end

  def price(usage, _endpoint), do: usage

  defp number(n) when is_number(n), do: n
  defp number(_), do: 0
end
