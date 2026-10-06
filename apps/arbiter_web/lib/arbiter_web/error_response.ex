defmodule ArbiterWeb.ErrorResponse do
  @moduledoc """
  The `{error: {type, message, details}}` response for code that cannot go
  through `ArbiterWeb.Api.FallbackController` — plugs (auth, the worker bridge)
  and the streaming `/api/events` action, which answer before or outside an
  `action_fallback`. The kind → type/status table is `Arbiter.Errors`, the same
  one the fallback and the MCP transport use, so an auth refusal reads like
  every other refusal.
  """

  import Plug.Conn

  alias Arbiter.Errors

  @doc "Send the error for `kind` and halt the connection."
  @spec halt_with(Plug.Conn.t(), Errors.kind(), String.t(), map(), keyword()) :: Plug.Conn.t()
  def halt_with(conn, kind, message, details \\ %{}, opts \\ []) do
    conn
    |> send_error(kind, message, details, opts)
    |> halt()
  end

  @doc "Send the error for `kind`; the caller decides whether to halt."
  @spec send_error(Plug.Conn.t(), Errors.kind(), String.t(), map(), keyword()) ::
          Plug.Conn.t()
  def send_error(conn, kind, message, details \\ %{}, opts \\ []) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      Errors.http_status(kind),
      Jason.encode!(Errors.body(kind, message, details, opts))
    )
  end
end
