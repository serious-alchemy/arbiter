defmodule ArbiterWeb.Api.BreakerController do
  @moduledoc """
  REST endpoints for the shared circuit breaker (bd-5jr49o) — the transport
  behind `arb breaker list` / `arb breaker reset`.

  Routes:

    * `GET  /api/breakers` — live breaker state plus the static registry of
      gated call sites (`?workspace=` — id or name, `workspace_id` accepted as an alias —
      `?kind=`, `?open_only=true`; no workspace means all of them)
    * `POST /api/breakers/reset` — close one breaker by `signature`, or every
      breaker matching `workspace` / `kind` when `all` is set, or clear one
      provider's auth-shaped dispatch hold with `provider` (bd-21bmdh; the
      listing reports those under `auth_holds`)

  The registry is returned unconditionally so a freshly-restarted server still
  answers "what is gated?" before any breaker has fired.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.CircuitBreaker
  alias Arbiter.Params
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  @doc "Live breaker state plus the call-site registry."
  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, kind} <- resolve_kind(params["kind"]),
         {:ok, open_only?} <- params |> Params.fetch_bool("open_only", false) |> Params.to_rest() do
      filters =
        []
        |> maybe_put(:workspace_id, ws_id)
        |> maybe_put(:kind, kind)
        |> maybe_put(:open_only, open_only?)

      breakers = CircuitBreaker.list(filters)

      json(conn, %{
        breakers: Enum.map(breakers, &serialize/1),
        open_count: Enum.count(breakers, & &1.open?),
        workspace_id: ws_id,
        call_sites: Enum.map(CircuitBreaker.call_sites(), &serialize_site/1),
        auth_holds: Enum.map(AuthHold.list(), &AuthHold.serialize/1),
        credential_watchdog: CredentialWatchdog.list()
      })
    end
  end

  @doc "Close one breaker by signature, or a whole scope with `all`."
  def reset(conn, %{"provider" => name}) do
    case AuthHold.resolve_provider(name) do
      {:ok, adapter} ->
        {:ok, cleared} = AuthHold.reset(adapter)
        json(conn, %{reset: length(cleared), auth_hold: name})

      :error ->
        {:error, {:invalid_request, "unknown provider #{inspect(name)}"}}
    end
  end

  def reset(conn, params) do
    with {:ok, all?} <- params |> Params.fetch_bool("all", false) |> Params.to_rest() do
      reset_scope(conn, params, all?)
    end
  end

  defp reset_scope(conn, params, all?) do
    case blank_to_nil(params["signature"]) do
      nil when all? ->
        reset_all(conn, params)

      nil ->
        {:error,
         {:invalid_request,
          "pass `signature` to reset one breaker, or `all: true` to reset a scope"}}

      signature ->
        with {:ok, _kind} <- resolve_kind(params["kind"]) do
          reset_signature(conn, signature)
        end
    end
  end

  # `kind` is resolved BEFORE the reset runs: a misspelled kind must not
  # degrade into "no filter" and re-arm every breaker in the workspace when
  # the operator asked for one.
  defp reset_all(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, kind} <- resolve_kind(params["kind"]),
         {:ok, confirm?} <- params |> Params.fetch_bool("confirm_all", false) |> Params.to_rest(),
         filters = [] |> maybe_put(:workspace_id, ws_id) |> maybe_put(:kind, kind),
         {:ok, count} <- scope_reset(filters, confirm?) do
      json(conn, %{reset: count, workspace_id: ws_id})
    end
  end

  defp scope_reset(filters, confirm?) do
    case CircuitBreaker.reset_scope(filters, confirm?) do
      {:error, :unscoped} -> {:error, {:invalid_request, CircuitBreaker.unscoped_message()}}
      ok -> ok
    end
  end

  defp reset_signature(conn, signature) do
    case CircuitBreaker.reset(signature) do
      :ok ->
        json(conn, %{reset: 1, signature: signature})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # The registry is a closed set, so a kind name resolves to an existing atom
  # rather than minting one from user input. Three outcomes, not two: absent
  # (no filter), known (filter), and unknown — which is an error, mirroring
  # `Arbiter.MCP.Tools.Breaker.kind_arg/1`, so the two operator surfaces agree.
  # An empty value is "absent": `?kind=` is what a query string produces for an
  # unset filter.
  defp resolve_kind(name) when name in [nil, ""], do: {:ok, nil}

  defp resolve_kind(name) when is_binary(name) do
    case Enum.find(CircuitBreaker.call_sites(), &(to_string(&1.kind) == name)) do
      nil -> {:error, {:invalid_request, "unknown breaker kind #{inspect(name)}"}}
      site -> {:ok, site.kind}
    end
  end

  defp resolve_kind(other),
    do: {:error, {:invalid_request, "kind must be a string, got #{inspect(other)}"}}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_), do: nil

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, _key, false), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp serialize(entry) do
    %{
      signature: entry.signature,
      workspace_id: entry.workspace_id,
      kind: to_string(entry.kind),
      subject: entry.subject,
      count: entry.count,
      suppressed: entry.suppressed,
      limit: entry.limit,
      window_ms: entry.window_ms,
      open: entry.open?,
      first_at: iso(entry.first_at),
      last_at: iso(entry.last_at),
      tripped_at: iso(entry.tripped_at)
    }
  end

  defp serialize_site(site) do
    %{
      kind: to_string(site.kind),
      module: inspect(site.module),
      description: site.description,
      limit: site.limit,
      window_ms: site.window_ms
    }
  end

  defp iso(nil), do: nil

  defp iso(ms) when is_integer(ms),
    do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
