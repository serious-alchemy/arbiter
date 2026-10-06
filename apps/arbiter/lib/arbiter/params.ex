defmodule Arbiter.Params do
  @moduledoc """
  The one place REST controllers and MCP tool handlers coerce loose wire
  input (JSON values or query strings) and handle attribution.

  ## Coercion

    * `boolean/1` — `true | "true" | "1" | 1` and `false | "false" | "0" | 0`;
      anything else is `:error`, never silently "true" or "unset".
    * `integer/1`, `limit/3` — integers or integer strings; `limit/3` applies a
      default and a hard cap (values above the cap clamp; zero, negative and
      junk are rejected).

  Errors are `{:error, {:invalid, message}}`, the shape MCP tools already use;
  REST adapters map it to a 400 `invalid_request`.

  ## List caps

  Every list route clamps `limit` to a documented maximum (default / max):

    * `GET /api/messages`, `GET /api/external_reviews` — 50 / 500
    * `GET /api/workers/history` — 20 / 200
    * `GET /api/usage/events` — 50 / 1000; `GET /api/usage` (summary) — none / 1000
    * `GET /api/loop/pending`, loop analysis — none / 500
    * MCP `notify_list` — 20 / 500; `worker_runs`, `external_review_list` — 20 / 200;
      `run_log_list` — 200 / 1000; `usage_summarize` — none / 1000; `loop_pending_list` — none / 500

  ## Attribution

  Attribution is derived from the bearer token (`Arbiter.Actor.from_scope/1`),
  never asserted by the caller. `strip_attribution/1` removes `actor`,
  `created_by`, `surface`, `by` and `change_origin` from request params on a
  coordinator route; a caller-supplied label may only be kept as metadata
  under a different key.
  """

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope

  @attribution_keys ~w(actor created_by surface by change_origin)

  @doc "Param keys a caller can never assert on a coordinator route."
  @spec attribution_keys() :: [String.t()]
  def attribution_keys, do: @attribution_keys

  @spec boolean(term()) :: {:ok, boolean()} | :error
  def boolean(v) when v in [true, "true", "1", 1], do: {:ok, true}
  def boolean(v) when v in [false, "false", "0", 0], do: {:ok, false}
  def boolean(_), do: :error

  @spec fetch_bool(map(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, {:invalid, String.t()}}
  def fetch_bool(args, key, default) do
    case fetch_optional_bool(args, key) do
      {:ok, nil} -> {:ok, default}
      other -> other
    end
  end

  @doc "Tri-state: `{:ok, nil}` when absent, `{:ok, bool}` when present."
  @spec fetch_optional_bool(map(), String.t()) ::
          {:ok, boolean() | nil} | {:error, {:invalid, String.t()}}
  def fetch_optional_bool(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      v ->
        case boolean(v) do
          {:ok, b} -> {:ok, b}
          :error -> {:error, {:invalid, "`#{key}` must be a boolean"}}
        end
    end
  end

  @spec integer(term()) :: {:ok, integer()} | :error
  def integer(n) when is_integer(n), do: {:ok, n}

  def integer(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def integer(_), do: :error

  @doc """
  A list `limit`: absent/blank → `default`; positive integer → itself; both
  clamped to `max`. Zero, negatives and junk are invalid.
  """
  @spec limit(term(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, {:invalid, String.t()}}
  def limit(raw, default, max) when raw in [nil, ""], do: {:ok, min(default, max)}

  def limit(raw, _default, max) do
    case integer(raw) do
      {:ok, n} when n > 0 -> {:ok, min(n, max)}
      _ -> {:error, {:invalid, "limit must be a positive integer"}}
    end
  end

  @doc "Map a `{:error, {:invalid, msg}}` coercion failure to the REST `:invalid_request` shape."
  @spec to_rest({:ok, term()} | {:error, {:invalid, String.t()}}) ::
          {:ok, term()} | {:error, {:invalid_request, String.t()}}
  def to_rest({:error, {:invalid, msg}}), do: {:error, {:invalid_request, msg}}
  def to_rest(other), do: other

  @spec strip_attribution(map()) :: map()
  def strip_attribution(params) when is_map(params), do: Map.drop(params, @attribution_keys)

  @doc "The attribution label for a request's token scope (nil without one)."
  @spec actor_label(Scope.t() | nil) :: String.t() | nil
  def actor_label(nil), do: nil

  def actor_label(%Scope{} = scope) do
    case Actor.from_scope(scope) do
      nil -> nil
      actor -> Actor.label(actor)
    end
  end
end
