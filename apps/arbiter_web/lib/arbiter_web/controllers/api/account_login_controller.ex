defmodule ArbiterWeb.Api.AccountLoginController do
  @moduledoc """
  REST endpoints behind `arb account login <ref>` (login relay 6/6, bd-bh50vs):
  drive a `Arbiter.Accounts.LoginRunner` through `Arbiter.Accounts.Logins`.

    * `POST /api/accounts/:ref/login`       — :create, starts a login
    * `GET  /api/account_logins/:id`        — :show, the live state (or the
      recorded outcome once the runner is gone)
    * `POST /api/account_logins/:id/paste`  — :paste (`code`), relays a pasted
      code. The code travels in the body, never a URL or argv, and `code` is
      in `:phoenix, :filter_parameters`.
    * `POST /api/account_logins/:id/cancel` — :cancel

  Every reply is the login state `%{id, status, url, device_code, needs_paste,
  reason}`; `status` is one of `starting`, `awaiting_user`, `verifying`,
  `succeeded`, `failed`, `timed_out`, `cancelled`.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts.Logins

  action_fallback ArbiterWeb.Api.FallbackController

  def create(conn, %{"ref" => ref}) do
    with {:ok, id} <- ref |> Logins.start(started_by: "cli") |> friendly(),
         {:ok, state} <- Logins.status(id) do
      conn |> put_status(:created) |> json(render_state(state))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, state} <- Logins.status(id), do: json(conn, render_state(state))
  end

  def paste(conn, %{"id" => id, "code" => code}) when is_binary(code) do
    with :ok <- id |> Logins.relay_paste(code) |> friendly(),
         {:ok, state} <- Logins.status(id) do
      json(conn, render_state(state))
    end
  end

  def paste(_conn, _params), do: {:error, {:invalid_request, "code is required"}}

  def cancel(conn, %{"id" => id}) do
    with :ok <- Logins.cancel(id),
         {:ok, state} <- Logins.status(id) do
      json(conn, render_state(state))
    end
  end

  defp render_state(state) do
    %{
      id: state.id,
      provider: state.provider,
      account: state.account,
      status: state.status,
      url: state.url,
      device_code: state.device_code,
      needs_paste: state.needs_paste?,
      reason: state.reason
    }
  end

  defp friendly({:ok, _} = ok), do: ok
  defp friendly(:ok), do: :ok
  defp friendly({:error, :not_found} = err), do: err

  defp friendly({:error, :ambiguous}),
    do: {:error, {:invalid_request, "ambiguous account reference — use provider:slug"}}

  defp friendly({:error, :already_active}),
    do: {:error, {:conflict, "a login is already running for this account"}}

  defp friendly({:error, :not_awaiting_code}),
    do: {:error, {:conflict, "the login is not waiting for a code"}}

  defp friendly({:error, :invalid_input}),
    do: {:error, {:invalid_request, "the code must be one printable line"}}

  defp friendly({:error, :relay_failed}),
    do: {:error, {:invalid_request, "the code could not be delivered to the login"}}

  defp friendly({:error, reason}) when reason in [:unsupported, :disabled, :unknown],
    do: {:error, {:invalid_request, "dashboard login is #{reason} for this provider"}}

  defp friendly({:error, :invalid_account}),
    do: {:error, {:invalid_request, "the account slug is not a valid login name"}}

  defp friendly({:error, other}),
    do: {:error, {:invalid_request, "login failed: #{inspect(other)}"}}
end
