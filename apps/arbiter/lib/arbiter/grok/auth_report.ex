defmodule Arbiter.Grok.AuthReport do
  @moduledoc """
  The doctor's view of grok's login (bd-dpv4vt, bd-8rvkqd): `GET /api/server/grok_auth`,
  `arb server doctor`.

  grok is off by default, so the report only looks at the credential when some
  workspace uses grok (`Arbiter.Agents.GrokRouting.in_use?/1`); otherwise it is
  `%{enabled: false}` and the doctor says nothing is wrong.

  It reads **the file the broker reads** (`Arbiter.Grok.CredentialStore.resolve/1`:
  the grok provider account's `auth.json`, where the dashboard login relay
  writes), never a stale `~/.grok` copy, and reports its `path`, `path_source`
  and `expires_at`. The state is one of:

    * `logged_in`: the access token is still valid.
    * `expired`: past its `expires_at`, but the broker's last refresh succeeded,
      so the next dispatch refreshes it. The only expired state that is ok.
    * `refresh_unverified`: expired and the broker has not refreshed it
      successfully since it booted. With `probe: true` (the doctor route) the
      report makes that attempt itself, through the broker (the single
      refresher), so this state is what is left when it cannot be made.
    * `refresh_failed`: expired and the broker's last refresh failed (issuer
      unreachable, 5xx).
    * `reauth_required`: the broker holds a refused refresh token.
    * `not_logged_in`: no usable login at the path.

  Everything but `logged_in` / `expired` carries a `fix`. Token values never
  appear.
  """

  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Grok.CredentialBroker
  alias Arbiter.Grok.CredentialStore
  alias Arbiter.Tasks.Workspace

  @type state ::
          :logged_in
          | :expired
          | :refresh_unverified
          | :refresh_failed
          | :reauth_required
          | :not_logged_in

  @ok_states [:logged_in, :expired]

  @doc """
  The report. Options: `:workspaces`, `:now`, `:probe` (see the moduledoc),
  `:auth_path` / `:accounts` / `:accounts_root` (path resolution, see
  `CredentialStore.resolve/1`), `:broker` (the broker server), `:reauth_required`
  and `:broker_status` (overrides, for tests).
  """
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

    {path, source} =
      CredentialStore.resolve(Keyword.take(opts, [:auth_path, :accounts, :accounts_root]))

    {state, expires_at} = evaluate(path, now, opts)

    %{
      state: state,
      path: path,
      path_source: source,
      expires_at: expires_at && DateTime.to_iso8601(expires_at),
      fix: if(state not in @ok_states, do: fix(state, path, source))
    }
  end

  defp evaluate(path, now, opts) do
    case CredentialStore.read(path) do
      {:error, :not_logged_in} ->
        {:not_logged_in, nil}

      {:ok, creds} ->
        status = broker_status(opts)

        cond do
          reauth_required?(opts, status) -> {:reauth_required, creds.expires_at}
          not expired?(creds, now) -> {:logged_in, creds.expires_at}
          true -> expired(creds, status, path, now, opts)
        end
    end
  end

  defp expired?(%{expires_at: %DateTime{} = at}, now), do: DateTime.compare(at, now) != :gt
  defp expired?(_creds, _now), do: false

  # Expired at rest is normal for an idle fleet (the broker refreshes on the
  # next request) *only* while refreshing is known to work.
  defp expired(creds, status, path, now, opts) do
    case status && status.last_attempt do
      :ok ->
        {:expired, creds.expires_at}

      :transient ->
        {:refresh_failed, creds.expires_at}

      _never_or_unknown ->
        if Keyword.get(opts, :probe, false) and status != nil,
          do: probe(path, now, opts),
          else: {:refresh_unverified, creds.expires_at}
    end
  end

  # One real refresh through the broker, which stays the only writer. Then
  # re-read: the broker has rotated the file on success.
  defp probe(path, now, opts) do
    server = Keyword.get(opts, :broker, nil)
    fetch_opts = [task_id: "doctor"]

    reply =
      if server,
        do: CredentialBroker.fetch_token(fetch_opts, server),
        else: CredentialBroker.fetch_token(fetch_opts)

    expires_at =
      case CredentialStore.read(path) do
        {:ok, %{expires_at: at}} -> at
        _ -> nil
      end

    case reply do
      {:ok, _token} ->
        {if(expired?(%{expires_at: expires_at}, now), do: :refresh_unverified, else: :logged_in),
         expires_at}

      {:error, :reauth_required} ->
        {:reauth_required, expires_at}

      {:error, :not_logged_in} ->
        {:not_logged_in, expires_at}

      {:error, :unavailable} ->
        {:refresh_failed, expires_at}
    end
  end

  defp reauth_required?(opts, status) do
    case Keyword.get(opts, :reauth_required) do
      nil -> status != nil and status.reauth_required?
      value -> value
    end
  end

  defp broker_status(opts) do
    case Keyword.fetch(opts, :broker_status) do
      {:ok, status} ->
        status

      :error ->
        try do
          opts |> Keyword.get(:broker) |> status_of()
        catch
          :exit, _ -> nil
        end
    end
  end

  defp status_of(nil), do: CredentialBroker.status()
  defp status_of(server), do: CredentialBroker.status(server)

  defp fix(state, path, source) do
    where =
      case source do
        :account ->
          "Log in again from the dashboard (the grok provider account's login), which writes #{path}."

        :fallback ->
          "No grok provider account exists, so the broker reads #{path}: run " <>
            "`grok login --device-code` on the Arbiter host, or add a grok account and log in from the dashboard."

        :explicit ->
          "The broker is pinned to #{path} (`:grok_broker, :auth_path`): log in so that file holds a fresh grok login."
      end

    case state do
      :refresh_failed ->
        "The access token is expired and the last refresh failed (x.ai unreachable?). " <>
          "Check the server's network; if it persists: " <> where

      :refresh_unverified ->
        "The access token is expired and the broker could not refresh it. " <> where

      _ ->
        where
    end
  end
end
