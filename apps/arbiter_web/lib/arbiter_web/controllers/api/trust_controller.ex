defmodule ArbiterWeb.Api.TrustController do
  @moduledoc """
  REST surface for earned trust (G18, `docs/design/guardrail-profiles.md`
  §6.3–6.5). Backs `arb trust`.

    * `GET  /api/trust` — every subject's tier and record
      (`Arbiter.Loop.Trust.View.list/0`); with `?subject=provider/model`, that
      one subject in full: recent events, history and any pending promotion
      proposal.
    * `POST /api/trust/promote` — `subject`, `to`, `reason`. **Operator proof
      only** (`ArbiterWeb.ApiPolicy` `:operator`): `arb trust promote` mints its
      token over the operator socket. `Arbiter.Loop.Trust.promote/4` checks the
      authority again and records `actor: operator`.
    * `POST /api/trust/confirm` — `subject`: the coordinator confirms an
      automatic suspension (the subject drops to quarantine).
    * `POST /api/trust/dismiss` — `subject`, `reason`: the coordinator dismisses
      one as a false positive (its tier returns).

  There is no MCP twin of `promote`: no MCP tool, at any tier, can promote.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Loop.Trust
  alias Arbiter.Loop.Trust.View

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    with {:ok, detail} <- View.detail(subject), do: json(conn, %{subject: detail})
  end

  def index(conn, _params), do: json(conn, %{subjects: View.list()})

  def promote(conn, params) do
    case Trust.promote(params["subject"], params["to"], params["reason"],
           authority: authority(conn)
         ) do
      {:ok, %{record: record, proposal: proposal}} ->
        json(conn, %{
          promoted: true,
          subject: detail(record),
          proposal: proposal && proposal.id
        })

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  def confirm(conn, params) do
    params["subject"]
    |> Trust.confirm(authority: authority(conn), actor: actor())
    |> decided(conn, :confirmed)
  end

  def dismiss(conn, params) do
    params["subject"]
    |> Trust.dismiss(params["reason"], authority: authority(conn), actor: actor())
    |> decided(conn, :dismissed)
  end

  defp decided({:ok, record}, conn, verb),
    do: json(conn, %{verb => true, subject: detail(record)})

  defp decided({:error, reason}, _conn, _verb), do: {:error, error(reason)}

  defp detail(record) do
    {:ok, detail} = View.detail(Trust.key(record))
    detail
  end

  defp authority(conn), do: Authority.from_scope(conn.assigns[:mcp_scope])

  # The token's actor (`Arbiter.Actor`, installed by `ApiAuth`), else the
  # coordinator: only a coordinator-tier token reaches these routes.
  defp actor, do: Arbiter.Actor.resolve_label(nil) || "coordinator"

  defp error({:operator_only, message}), do: {:forbidden, message}
  defp error({kind, message}) when kind in [:forbidden, :invalid], do: {kind, message}
  defp error(other), do: {:server_error, "trust request failed: #{inspect(other)}"}
end
