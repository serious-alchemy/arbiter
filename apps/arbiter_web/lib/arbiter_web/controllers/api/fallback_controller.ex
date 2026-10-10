defmodule ArbiterWeb.Api.FallbackController do
  @moduledoc """
  Translates `{:error, _}` tuples returned by API controller actions into
  consistent JSON error responses.

  Error format (all 4xx responses):

      {"error": {"type": "...", "message": "...", "details": {...}}}

  Where `type` is one of:

    * `"validation_error"` — 422 — `%Ash.Error.Invalid{}` or `{:invalid, msg}`:
      the request is well formed but an argument is unacceptable.
    * `"not_found"` — 404 — `%Ash.Error.Query.NotFound{}`
    * `"invalid_request"` — 400 — malformed params (missing, mistyped, bad atom
      values etc.)
    * `"conflict"` — 409 — the request is well-formed but the resource is
      already in the state it asks for, and doing it twice would be harmful
      (e.g. starting a second merge Watchdog on one MR).
    * `"busy"` — 503 — a transient failure to reach an in-process resource
      (e.g. a `GenServer.call` timeout) — safe to retry after a short wait.
    * `"tracker_error"` — varies — a normalised error struct from any tracker
      adapter (`GitHub`, `Jira`, `Shortcut`, …). The HTTP status is derived
      from the error `kind` so every tracker reports failures the same way.
    * `"unauthorized"` / `"forbidden"` — 403, `"unauthenticated"` — 401.
    * `"internal_error"` — 500 — `{:server_error, msg, details}` keeps the real
      message; anything unrecognised falls through to a generic 500.

  The kind → type/status table is `Arbiter.Errors`, shared with the MCP
  transport so a client can branch on `type` on either surface.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Errors

  @domain_kinds ~w(not_found invalid invalid_request conflict already_claimed not_assigned busy
                   forbidden unauthorized unauthenticated internal server_error)a

  def call(conn, {:error, %Ash.Error.Invalid{} = err}) do
    if contains_not_found?(err) do
      conn
      |> put_status(:not_found)
      |> json(%{error: %{type: "not_found", message: "resource not found", details: %{}}})
    else
      details = ash_invalid_details(err)

      conn
      |> put_status(:unprocessable_entity)
      |> json(%{
        error: %{
          type: "validation_error",
          message: validation_message(details),
          details: details
        }
      })
    end
  end

  def call(conn, {:error, %Ash.Error.Query.NotFound{}}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{type: "not_found", message: "resource not found", details: %{}}
    })
  end

  def call(conn, {:error, %Ash.Error.Forbidden{} = err}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{type: "forbidden", message: Exception.message(err), details: %{}}
    })
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{type: "not_found", message: "resource not found", details: %{}}
    })
  end

  # Every domain refusal tuple — `{kind, message}` or `{kind, message, details}` —
  # renders through `Arbiter.Errors`, so one kind is one status and one `type`
  # on every controller (and the MCP transport reads the same table).
  def call(conn, {:error, {kind, message}}) when kind in @domain_kinds and is_binary(message),
    do: render_error(conn, kind, message, %{})

  def call(conn, {:error, {kind, message, details}})
      when kind in @domain_kinds and is_binary(message) and is_map(details),
      do: render_error(conn, kind, message, details)

  # Tracker adapter errors share an identical normalised shape
  # (`%{kind, status, message, raw}`) across every backend. Render them all
  # through one helper so a Jira or Shortcut failure reports the same way a
  # GitHub one always has.
  def call(conn, {:error, %Arbiter.Trackers.GitHub.Error{} = err}),
    do: tracker_error_response(conn, err)

  def call(conn, {:error, %Arbiter.Trackers.Jira.Error{} = err}),
    do: tracker_error_response(conn, err)

  def call(conn, {:error, %Arbiter.Trackers.Shortcut.Error{} = err}),
    do: tracker_error_response(conn, err)

  def call(conn, {:error, %Ash.Error.Unknown{} = err}) do
    # Surface the cause when we can but never the full stack.
    causes = err |> Map.get(:errors, []) |> Enum.map(&inspect/1)

    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        type: "internal_error",
        message: "internal server error",
        details: %{causes: causes}
      }
    })
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        type: "internal_error",
        message: "internal server error",
        details: %{reason: inspect(reason)}
      }
    })
  end

  # --- helpers ---

  defp render_error(conn, kind, message, details) do
    conn
    |> put_status(Errors.http_status(kind))
    |> json(Errors.body(kind, message, details))
  end

  # Map a normalised tracker error to a JSON response. The struct shape is
  # identical across adapters, so we match structurally on the fields rather
  # than per-adapter. `kind` drives the HTTP status.
  defp tracker_error_response(conn, %{kind: kind, status: status, message: message}) do
    http_status =
      case kind do
        :config_missing -> :bad_request
        :unauthenticated -> :unauthorized
        :forbidden -> :forbidden
        :not_found -> :not_found
        :validation_failed -> :unprocessable_entity
        _ -> :bad_gateway
      end

    conn
    |> put_status(http_status)
    |> json(%{
      error: %{
        type: "tracker_error",
        message: message,
        details: %{kind: Atom.to_string(kind), status: status}
      }
    })
  end

  defp contains_not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  # A single validation error is common (e.g. bd-7mbrlg's acceptance-criteria
  # guard) and its message is specific enough to surface directly, sparing
  # callers (like the CLI) a round-trip through `details.errors` just to show
  # the operator what actually went wrong. Multiple errors keep the generic
  # top-level message — `details.errors` still lists every one of them.
  defp validation_message(%{errors: [%{message: message}]}) when is_binary(message),
    do: message

  defp validation_message(_), do: "validation failed"

  defp ash_invalid_details(%Ash.Error.Invalid{errors: errors}) do
    %{
      errors:
        Enum.map(errors, fn err ->
          %{
            field: error_field(err),
            message: error_message(err)
          }
        end)
    }
  end

  defp error_field(%{field: field}) when not is_nil(field), do: to_string(field)
  defp error_field(%{fields: [field | _]}) when not is_nil(field), do: to_string(field)
  defp error_field(_), do: nil

  defp error_message(err) do
    cond do
      function_exported?(err.__struct__, :message, 1) -> Exception.message(err)
      Map.has_key?(err, :message) and is_binary(err.message) -> err.message
      true -> inspect(err)
    end
  end
end
