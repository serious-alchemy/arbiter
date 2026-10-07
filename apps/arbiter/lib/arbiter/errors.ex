defmodule Arbiter.Errors do
  @moduledoc """
  The one error taxonomy shared by the REST fallback, the MCP transport and
  (via the HTTP status the REST layer derives from it) the CLI exit codes.

  A domain refusal is `{:error, {kind, message}}` or
  `{:error, {kind, message, details}}`. The `kind` decides the wire `type` and
  the HTTP status, so the same refusal reads the same on every surface:

    * `:not_found` — 404 `not_found` — the thing named does not exist.
    * `:invalid` — 422 `validation_error` — the request is well formed but an
      argument is unacceptable.
    * `:invalid_request` — 400 `invalid_request` — the request itself is
      malformed (a missing or mistyped parameter).
    * `:conflict` — 409 `conflict` — the request is well formed and valid, the
      current state refuses it (closed ticket, live session, full account).
    * `:already_claimed` — 409 `already_claimed` — another Arbiter installation
      already claimed the tracker issue (`force` overrides).
    * `:not_assigned` — 403 `not_assigned` — the tracker issue is not assigned to
      the workspace user (`force` overrides).
    * `:bad_gateway` — 502 `bad_gateway` — an upstream system (the tracker)
      failed; our side may have succeeded (the ticket exists).
    * `:busy` — 503 `busy` — a transient condition; retry after a short wait.
    * `:forbidden` / `:unauthorized` — 403 — the caller may not.
    * `:unauthenticated` — 401 — no usable credential.
    * `:internal` / `:server_error` — 500 `internal_error` — our bug or an
      unmapped failure; the real message is still carried.

  Historic aliases (`:invalid_args`, `:unknown_provider`) fold into `:invalid`.
  """

  @kinds %{
    not_found: {"not_found", 404},
    invalid: {"validation_error", 422},
    invalid_args: {"validation_error", 422},
    unknown_provider: {"validation_error", 422},
    invalid_request: {"invalid_request", 400},
    conflict: {"conflict", 409},
    already_claimed: {"already_claimed", 409},
    not_assigned: {"not_assigned", 403},
    bad_gateway: {"bad_gateway", 502},
    busy: {"busy", 503},
    forbidden: {"forbidden", 403},
    unauthorized: {"unauthorized", 403},
    unauthenticated: {"unauthenticated", 401},
    internal: {"internal_error", 500},
    server_error: {"internal_error", 500}
  }

  @type kind :: atom()

  @doc "The wire `type` string for a kind; unknown kinds are `\"internal_error\"`."
  @spec type(kind()) :: String.t()
  def type(kind), do: kind |> lookup() |> elem(0)

  @doc "The HTTP status for a kind; unknown kinds are 500."
  @spec http_status(kind()) :: pos_integer()
  def http_status(kind), do: kind |> lookup() |> elem(1)

  @doc """
  The `{error: {type, message, details}}` envelope every REST error carries.
  `type:` overrides the kind's own `type` for the few endpoints whose callers
  branch on a finer, documented one (e.g. `grok_reauth_required`); the status
  still comes from the kind.
  """
  @spec body(kind(), String.t(), map(), keyword()) :: %{
          error: %{type: String.t(), message: String.t(), details: map()}
        }
  def body(kind, message, details \\ %{}, opts \\ []) do
    %{error: %{type: Keyword.get(opts, :type, type(kind)), message: message, details: details}}
  end

  defp lookup(kind), do: Map.get(@kinds, kind, {"internal_error", 500})
end
