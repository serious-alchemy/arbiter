defmodule Arbiter.Grok.AuthReport do
  @moduledoc """
  The doctor's view of grok's login (bd-dpv4vt): `GET /api/server/grok_auth`,
  `arb server doctor`.

  grok is off by default, so the report only looks at the credential when some
  workspace uses grok (`Arbiter.Agents.GrokRouting.in_use?/1`); otherwise it is
  `%{enabled: false}` and the doctor says nothing is wrong. When it is in use
  the state is one of `logged_in`, `expired` (the access token is past its
  `expires_at`; the broker refreshes it on the next dispatch, so this is a
  warning-free state), `reauth_required` (the broker holds a refused refresh
  token), or `not_logged_in`. Token values never appear.
  """

  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Grok.CredentialBroker
  alias Arbiter.Grok.CredentialStore
  alias Arbiter.Tasks.Workspace

  @fix "Run `grok login --device-code` on the Arbiter host (or log in from the dashboard's Providers page)."

  @type state :: :logged_in | :expired | :reauth_required | :not_logged_in

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    workspaces =
      opts
      |> Keyword.get_lazy(:workspaces, fn -> Ash.read!(Workspace) end)
      |> Enum.filter(&GrokRouting.in_use?/1)
      |> Enum.map(& &1.name)

    case workspaces do
      [] -> %{enabled: false, workspaces: []}
      names -> Map.merge(%{enabled: true, workspaces: names}, auth(opts))
    end
  end

  defp auth(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    state =
      case CredentialStore.read(auth_path(opts)) do
        {:error, :not_logged_in} -> :not_logged_in
        {:ok, creds} -> if reauth_required?(opts), do: :reauth_required, else: expiry(creds, now)
      end

    %{state: state, fix: if(state in [:not_logged_in, :reauth_required], do: @fix)}
  end

  defp expiry(%{expires_at: %DateTime{} = at}, now),
    do: if(DateTime.compare(at, now) == :gt, do: :logged_in, else: :expired)

  defp expiry(_creds, _now), do: :logged_in

  defp reauth_required?(opts) do
    case Keyword.get(opts, :reauth_required) do
      nil ->
        try do
          CredentialBroker.status().reauth_required?
        catch
          :exit, _ -> false
        end

      value ->
        value
    end
  end

  defp auth_path(opts) do
    Keyword.get_lazy(opts, :auth_path, fn ->
      :arbiter
      |> Application.get_env(:grok_broker, [])
      |> Keyword.get(:auth_path, CredentialStore.default_path())
      |> Path.expand()
    end)
  end
end
