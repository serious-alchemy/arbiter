defmodule ArbiterWeb.Plugs.ApiConcurrencyLimit do
  @moduledoc """
  Bounds how many `/api` requests are in flight at once (bd-66anxj).

  2026-10-10: ~680 concurrent `arb` processes drove the server to 6.5 GB and
  starved the DB pool until the kernel OOM-killed it. Over the limit a request
  is refused immediately with a `503 busy` and `Retry-After`, instead of
  queuing and growing the heap; the `arb` CLI backs off and retries.

  The limit is `config :arbiter_web, :api_max_concurrency` (default
  128; `ARBITER_API_MAX_CONCURRENCY` sets it at boot). `0` or `:infinity`
  disables the limit. `GET /api/events` is a long-lived SSE stream, not
  a request in the burst sense, so it is exempt.

  Slots are held by the request process and released when the response is
  sent; if the process dies first, the limiter's monitor releases it.
  """

  @behaviour Plug

  import Plug.Conn

  alias ArbiterWeb.ErrorResponse
  alias ArbiterWeb.Plugs.ApiConcurrencyLimit.Counter

  @default_limit 128
  @retry_after "1"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/api/events"} = conn, _opts), do: conn

  def call(conn, _opts) do
    case limit() do
      :infinity ->
        conn

      max ->
        case Counter.acquire(self(), max) do
          :ok ->
            register_before_send(conn, fn conn ->
              Counter.release(self())
              conn
            end)

          :full ->
            conn
            |> put_resp_header("retry-after", @retry_after)
            |> ErrorResponse.halt_with(
              :busy,
              "server is handling too many concurrent API requests; retry shortly",
              %{limit: max}
            )
        end
    end
  end

  @doc "Number of `/api` requests currently holding a slot."
  @spec in_flight() :: non_neg_integer()
  def in_flight, do: Counter.in_flight()

  defp limit do
    case Application.get_env(:arbiter_web, :api_max_concurrency, @default_limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> :infinity
    end
  end
end
