defmodule ArbiterWeb.Api.FallbackControllerTest do
  @moduledoc """
  The one error taxonomy (bd-5fc29i / P-06): every `{:error, _}` shape the API
  controllers produce goes through the fallback and lands on one status and one
  `{error: {type, message, details}}` body.
  """
  use ArbiterWeb.ConnCase, async: true

  alias ArbiterWeb.Api.FallbackController

  defp render(error) do
    conn = FallbackController.call(Phoenix.ConnTest.build_conn(), {:error, error})
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  @cases [
    # {error, status, type}
    {:not_found, 404, "not_found"},
    {%Ash.Error.Query.NotFound{}, 404, "not_found"},
    {{:invalid_request, "bad param"}, 400, "invalid_request"},
    {{:invalid_request, "bad param", %{field: "x"}}, 400, "invalid_request"},
    {{:invalid, "bad value"}, 422, "validation_error"},
    {{:invalid, "bad value", %{field: "x"}}, 422, "validation_error"},
    {{:conflict, "state refuses"}, 409, "conflict"},
    {{:conflict, "state refuses", %{holders: []}}, 409, "conflict"},
    {{:busy, "try later"}, 503, "busy"},
    {{:busy, "try later", %{retry: true}}, 503, "busy"},
    {{:unauthorized, "not for this token"}, 403, "unauthorized"},
    {{:forbidden, "nope"}, 403, "forbidden"},
    {{:unauthenticated, "who are you"}, 401, "unauthenticated"},
    {{:server_error, "dispatch failed", %{reason: ":boom"}}, 500, "internal_error"},
    {{:internal, "kaboom"}, 500, "internal_error"},
    {%Ash.Error.Forbidden{}, 403, "forbidden"},
    {%Ash.Error.Unknown{errors: []}, 500, "internal_error"},
    {:some_unmapped_atom, 500, "internal_error"},
    {%Arbiter.Trackers.GitHub.Error{kind: :not_found, status: 404, message: "m"}, 404,
     "tracker_error"},
    {%Arbiter.Trackers.GitHub.Error{kind: :other, status: 500, message: "m"}, 502,
     "tracker_error"}
  ]

  for {error, status, type} <- @cases do
    test "#{inspect(error)} -> #{status} #{type}" do
      {status, body} = render(unquote(Macro.escape(error)))
      assert status == unquote(status)

      assert %{"error" => %{"type" => unquote(type), "message" => msg, "details" => details}} =
               body

      assert is_binary(msg) and is_map(details)
    end
  end

  test "{:server_error, msg, details} keeps the real message and details" do
    {500, %{"error" => err}} = render({:server_error, "resume failed", %{reason: ":boom"}})
    assert err["message"] == "resume failed"
    assert err["details"] == %{"reason" => ":boom"}
  end

  test "a conflict carries its details" do
    {409, %{"error" => err}} = render({:conflict, "full", %{cap: 2}})
    assert err["details"] == %{"cap" => 2}
  end

  test "an Ash validation error is a 422 validation_error" do
    {422, %{"error" => %{"type" => "validation_error"}}} =
      render(%Ash.Error.Invalid{errors: [%Ash.Error.Changes.Required{field: :title}]})
  end
end
