defmodule Arbiter.ErrorsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Errors

  @table [
    # kind, type, http status
    {:not_found, "not_found", 404},
    {:invalid, "validation_error", 422},
    {:invalid_args, "validation_error", 422},
    {:unknown_provider, "validation_error", 422},
    {:invalid_request, "invalid_request", 400},
    {:conflict, "conflict", 409},
    {:busy, "busy", 503},
    {:forbidden, "forbidden", 403},
    {:unauthorized, "unauthorized", 403},
    {:unauthenticated, "unauthenticated", 401},
    {:internal, "internal_error", 500},
    {:server_error, "internal_error", 500}
  ]

  for {kind, type, status} <- @table do
    test "#{kind} -> #{type} / #{status}" do
      assert Errors.type(unquote(kind)) == unquote(type)
      assert Errors.http_status(unquote(kind)) == unquote(status)
    end
  end

  test "an unknown kind is an internal error, never a crash" do
    assert Errors.type(:something_new) == "internal_error"
    assert Errors.http_status(:something_new) == 500
  end

  test "body/3 builds the one error envelope" do
    assert Errors.body(:conflict, "nope", %{a: 1}) ==
             %{error: %{type: "conflict", message: "nope", details: %{a: 1}}}

    assert Errors.body(:busy, "later").error.details == %{}
  end
end
