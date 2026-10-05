defmodule Arbiter.Grok.CredentialBroker do
  @moduledoc """
  The single refresher for grok's rotating OIDC credential (bd-9p4lx9).

  grok's `refresh_token` **rotates on every refresh**, and grok deletes its
  `auth.json` when a refresh is permanently refused. Copying the operator's
  `auth.json` into each worker's `GROK_HOME` therefore races: the first copy to
  refresh invalidates the operator's token and every other copy (the bd-6umoh9
  problem), and each loser then deletes its own file. So workers never hold the
  refresh token at all:

    * This process is the **only** holder of it. The canonical credential is
      one `auth.json` (`Arbiter.Grok.CredentialStore`; the operator's
      `~/.grok/auth.json` unless `:auth_path` says otherwise), and this is the
      only code that refreshes it.
    * A worker gets a short-lived **access token** through grok's documented
      `GROK_AUTH_PROVIDER_COMMAND` contract (see `Arbiter.Grok.AuthProvider`):
      the command asks the server over the worker's own API token, and
      `fetch_token/2` is what answers. The reply is exactly
      `%{access_token, expires_in}`.

  ## Single writer

  Every request is a call to this one process. A request that finds a token
  with more than `:refresh_margin_s` (default 600 s, comfortably above grok's
  own 300 s early-invalidation window) left is answered from the canonical file
  with no network. One that does not starts **one** refresh (a task under
  `Arbiter.TaskSupervisor`); every request arriving meanwhile queues behind it
  and gets its result. The rotated token pair is written back to the canonical
  file atomically before any waiter is answered.

  `force: true` is grok's `GROK_AUTH_EXPIRED=1`: the worker was told its token
  is no good (a 401, or its own expiry). It refreshes even a token that looks
  fresh, but not within `:min_force_interval_s` (default 60 s) of the last
  refresh: the worker that asks a moment after another worker's refresh is
  handed that worker's token, so N workers whose tokens lapse together cost one
  refresh.

  Before spending a refresh token the file is re-read, so the operator's own
  interactive grok refreshing the same file is adopted rather than raced. If a
  refresh is refused with `invalid_grant` and the file has meanwhile been
  rotated by someone else, the request is retried against the newer credential
  instead of declaring the login dead.

  ## Failure handling

    * **Permanent refusal** (`invalid_grant`, `invalid_client`,
      `unauthorized_client`; or no credential file at all): the operator has to
      log in again. The broker opens an auth hold for the provider —
      `Arbiter.Agents.CredentialWatchdog.mark_expired/3`, which closes the
      dispatch gate, pages the coordinators and shows up on the quota
      surfaces — and answers every request `{:error, :reauth_required}` (or
      `:not_logged_in`) at once, without asking the issuer again. The hold
      clears when the canonical file holds a credential other than the one that
      failed, i.e. after `grok login`. **The canonical file is never deleted,
      moved or rewritten on a failure.**
    * **Transient failure** (network, 5xx, 429): no hold. A still-valid token is
      served; an expired one is `{:error, :unavailable}` and the worker's own
      retry asks again.
    * **A refresh that succeeded but could not be written**: the rotated pair is
      the only valid credential from that moment, so it is kept in memory,
      served from there, and the write is retried on every later request. Losing
      it would force a re-login.

  Token values are never logged. Logs carry fingerprints, expiry times and OAuth
  error codes only.

  ## Configuration

      config :arbiter, :grok_broker,
        auth_path: "~/.grok/auth.json",
        refresh_margin_s: 600,
        min_force_interval_s: 60
  """

  use GenServer

  require Logger

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Grok.CredentialStore
  alias Arbiter.Grok.Oidc
  alias Arbiter.Worker.StopReason

  @default_margin_s 600
  @default_min_force_s 60
  @call_timeout 45_000

  @type token :: %{access_token: String.t(), expires_in: pos_integer()}
  @type error :: :reauth_required | :not_logged_in | :unavailable

  # ---- public API -------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  A current access token for a worker.

  `opts`: `force: true` for grok's `GROK_AUTH_EXPIRED=1` (see the moduledoc).
  Returns the access token and the seconds it has left, and nothing else: in
  particular never the refresh token.
  """
  @spec fetch_token(keyword(), GenServer.server()) :: {:ok, token()} | {:error, error()}
  def fetch_token(opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:fetch, Keyword.get(opts, :force, false) == true}, @call_timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Non-secret state for the doctor / operator surfaces."
  @spec status(GenServer.server()) :: %{
          reauth_required?: boolean(),
          refreshing?: boolean(),
          last_refresh_at: DateTime.t() | nil
        }
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ---- GenServer ----------------------------------------------------------------

  @impl true
  def init(opts) do
    env = Application.get_env(:arbiter, :grok_broker, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    {:ok,
     %{
       auth_path: Path.expand(get.(:auth_path, CredentialStore.default_path())),
       margin_s: get.(:refresh_margin_s, @default_margin_s),
       min_force_s: get.(:min_force_interval_s, @default_min_force_s),
       now_fun: get.(:now_fun, &DateTime.utc_now/0),
       req_options: get.(:req_options, []),
       watchdog: get.(:credential_watchdog, CredentialWatchdog),
       hold_adapter: get.(:hold_adapter, nil),
       refreshing: nil,
       pending: nil,
       last_refresh_at: nil,
       hold: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       reauth_required?: state.hold != nil,
       refreshing?: state.refreshing != nil,
       last_refresh_at: state.last_refresh_at
     }, state}
  end

  def handle_call({:fetch, force?}, from, state) do
    {:noreply, serve(from, force?, retry_pending(state))}
  end

  @impl true
  def handle_info({ref, result}, %{refreshing: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_refresh(result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{refreshing: %{ref: ref}} = state) do
    {:noreply, finish_refresh({:error, {:transient, :task_crashed}}, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- serving a request ------------------------------------------------------------

  defp serve(from, force?, state) do
    case load(state) do
      {:error, :not_logged_in} ->
        reply_all([from], {:error, :not_logged_in}, open_hold(state, :not_logged_in, nil))

      {:ok, creds} ->
        state = maybe_recover(state, creds)

        if state.hold do
          reply_all([from], {:error, hold_error(state.hold)}, state)
        else
          serve_loaded(from, force?, creds, state)
        end
    end
  end

  defp serve_loaded(from, force?, creds, state) do
    now = state.now_fun.()

    cond do
      state.refreshing != nil ->
        queue_waiter(state, from)

      refresh_needed?(creds, force?, now, state) ->
        start_refresh(state, creds, [from])

      true ->
        reply_all([from], {:ok, token_reply(creds, now)}, state)
    end
  end

  defp refresh_needed?(creds, force?, now, state) do
    remaining = remaining_s(creds, now)

    cond do
      remaining <= state.margin_s -> true
      force? -> not refreshed_within?(state, now, state.min_force_s)
      true -> false
    end
  end

  defp refreshed_within?(%{last_refresh_at: nil}, _now, _seconds), do: false

  defp refreshed_within?(%{last_refresh_at: at}, now, seconds),
    do: DateTime.diff(now, at, :second) < seconds

  defp remaining_s(%{expires_at: nil}, _now), do: -1
  defp remaining_s(%{expires_at: expires_at}, now), do: DateTime.diff(expires_at, now, :second)

  defp token_reply(creds, now),
    do: %{access_token: creds.access_token, expires_in: max(remaining_s(creds, now), 1)}

  defp queue_waiter(%{refreshing: refreshing} = state, from),
    do: %{state | refreshing: %{refreshing | waiters: [from | refreshing.waiters]}}

  defp reply_all(waiters, reply, state) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
    state
  end

  # ---- refreshing -------------------------------------------------------------------

  defp start_refresh(state, creds, waiters) do
    now = state.now_fun.()
    req_options = state.req_options

    task =
      Task.Supervisor.async_nolink(Arbiter.TaskSupervisor, fn ->
        Oidc.refresh(creds, now, req_options)
      end)

    %{state | refreshing: %{ref: task.ref, creds: creds, waiters: waiters}}
  end

  defp finish_refresh({:ok, rotated}, %{refreshing: %{creds: creds, waiters: waiters}} = state) do
    now = state.now_fun.()
    state = %{state | refreshing: nil, last_refresh_at: now}

    state =
      case CredentialStore.persist(state.auth_path, creds, rotated) do
        :ok ->
          %{state | pending: nil}

        {:error, reason} ->
          # The issuer already rotated the token: this pair is the only valid
          # credential now. Keep it, and keep trying to write it.
          Logger.error(
            "grok credential broker: refreshed the credential but could not write " <>
              "#{state.auth_path} (#{inspect(reason)}); holding the rotated token in memory " <>
              "and retrying the write on the next request"
          )

          %{
            state
            | pending: %{
                base: CredentialStore.fingerprint(creds.refresh_token),
                creds: creds,
                rotated: rotated
              }
          }
      end

    Logger.info(
      "grok credential broker: refreshed the access token " <>
        "(refresh token #{CredentialStore.fingerprint(creds.refresh_token)} → " <>
        "#{CredentialStore.fingerprint(rotated.refresh_token)}, " <>
        "expires #{DateTime.to_iso8601(rotated.expires_at)})"
    )

    served = Map.merge(creds, Map.take(rotated, [:access_token, :refresh_token, :expires_at]))
    reply_all(waiters, {:ok, token_reply(served, now)}, state)
  end

  defp finish_refresh({:error, {:permanent, code}}, %{refreshing: refreshing} = state) do
    %{creds: creds, waiters: waiters} = refreshing
    state = %{state | refreshing: nil}
    sent = CredentialStore.fingerprint(creds.refresh_token)

    case CredentialStore.read(state.auth_path) do
      {:ok, newer} ->
        if CredentialStore.fingerprint(newer.refresh_token) != sent do
          # Someone else (the operator's own grok) rotated the file while our
          # grant was in flight: our token was merely stale, the login is not
          # dead. Re-serve the waiters from what is canonical now.
          Logger.info(
            "grok credential broker: refresh refused (#{code}) but the canonical " <>
              "credential was rotated meanwhile; retrying against it"
          )

          Enum.reduce(Enum.reverse(waiters), state, fn from, acc -> serve(from, false, acc) end)
        else
          dead(state, waiters, code, sent)
        end

      {:error, :not_logged_in} ->
        dead(state, waiters, code, sent)
    end
  end

  defp finish_refresh({:error, {:transient, why}}, %{refreshing: refreshing} = state) do
    %{waiters: waiters} = refreshing
    state = %{state | refreshing: nil}
    Logger.warning("grok credential broker: refresh failed transiently (#{inspect(why)})")

    now = state.now_fun.()

    reply =
      case load(state) do
        {:ok, creds} ->
          if remaining_s(creds, now) > 0,
            do: {:ok, token_reply(creds, now)},
            else: {:error, :unavailable}

        {:error, :not_logged_in} ->
          {:error, :unavailable}
      end

    reply_all(waiters, reply, state)
  end

  defp dead(state, waiters, code, fingerprint) do
    state = open_hold(state, :invalid_grant, fingerprint, code)
    reply_all(waiters, {:error, :reauth_required}, state)
  end

  # ---- the canonical credential ----------------------------------------------------------

  # The in-memory pair wins only while it is the unwritten, newer-than-file one.
  defp load(%{pending: %{creds: creds, rotated: rotated}}),
    do: {:ok, Map.merge(creds, Map.take(rotated, [:access_token, :refresh_token, :expires_at]))}

  defp load(%{auth_path: path}), do: CredentialStore.read(path)

  defp retry_pending(%{pending: nil} = state), do: state

  defp retry_pending(%{pending: pending} = state) do
    case CredentialStore.read(state.auth_path) do
      {:ok, on_disk} ->
        if CredentialStore.fingerprint(on_disk.refresh_token) == pending.base do
          case CredentialStore.persist(state.auth_path, pending.creds, pending.rotated) do
            :ok ->
              Logger.info(
                "grok credential broker: wrote the previously unwritten rotated credential"
              )

              %{state | pending: nil}

            {:error, _reason} ->
              state
          end
        else
          # The file moved on (an operator login): it is canonical again.
          %{state | pending: nil}
        end

      {:error, :not_logged_in} ->
        state
    end
  end

  # ---- the auth hold ----------------------------------------------------------------------

  defp hold_error(%{kind: :not_logged_in}), do: :not_logged_in
  defp hold_error(%{kind: :invalid_grant}), do: :reauth_required

  defp open_hold(state, kind, fingerprint, code \\ nil)

  defp open_hold(%{hold: %{kind: kind}} = state, kind, _fingerprint, _code), do: state

  defp open_hold(state, kind, fingerprint, code) do
    why =
      case kind do
        :invalid_grant -> "the issuer refused the refresh token (#{code})"
        :not_logged_in -> "there is no usable grok login at #{state.auth_path}"
      end

    Logger.error(
      "grok credential broker: #{why}; grok workers are held until the operator logs in " <>
        "again (re-login: `grok login --device-code` on the Arbiter host). The canonical " <>
        "credential file was left untouched."
    )

    CredentialWatchdog.mark_expired(hold_adapter(state), stop_reason(why), state.watchdog)

    %{state | hold: %{kind: kind, fingerprint: fingerprint, since: state.now_fun.()}}
  end

  # The hold clears once the canonical file holds a credential other than the
  # one that failed — that is what `grok login` produces.
  defp maybe_recover(%{hold: nil} = state, _creds), do: state

  defp maybe_recover(%{hold: hold} = state, creds) do
    if hold.fingerprint != CredentialStore.fingerprint(creds.refresh_token) do
      Logger.info("grok credential broker: a new grok login was found; lifting the auth hold")
      CredentialWatchdog.mark_recovered(hold_adapter(state), state.watchdog)
      %{state | hold: nil}
    else
      state
    end
  end

  # The adapter module is the hold's identity. `Arbiter.Agents.adapters/0` knows
  # it once the grok adapter is registered; `Arbiter.Agents.Grok` is its name.
  defp hold_adapter(%{hold_adapter: adapter}) when is_atom(adapter) and adapter != nil,
    do: adapter

  defp hold_adapter(_state), do: Map.get(Arbiter.Agents.adapters(), :grok, Arbiter.Agents.Grok)

  defp stop_reason(why) do
    %StopReason{
      category: :auth_expired,
      summary: "grok login is dead: #{why}",
      remediation:
        "Log in to grok again on the Arbiter host (`grok login --device-code`). Arbiter's " <>
          "credential broker is the only refresher and has not touched the credential file. " <>
          "The hold lifts itself on the next worker request after the new login, or clear it " <>
          "with `arb breaker reset --auth-hold grok`.",
      exit_status: nil,
      signal: nil
    }
  end
end
