defmodule Arbiter.Accounts.LoginCompletion do
  @moduledoc """
  What a finished dashboard login does (login relay 4/6, bd-djh1yr, epic
  bd-dqvv90). `Arbiter.Accounts.LoginRunner` calls `complete/2` once per
  terminal state.

  On `:succeeded` — the recipe's status command has confirmed the login:

    1. **Record by reference.** The account's credential becomes a
       `:cli_credentials_path` row pointing at the CLI's own credential file in
       the dedicated config dir (`Arbiter.Accounts.reference_credential_path/2`).
       The file is never read into a row or copied: refresh-token rotation
       locks out copies (bd-6umoh9). Only Claude has a quota-grant consumer for
       that kind (`Arbiter.Quota.GrantFile`), so other providers are not given
       a row (`credential: :unsupported`) — the login is still recorded.
    2. **Clear the alerts.** The adapter's `credential_expired` system alerts
       (every source), the watchdog's expired mark, and the lapsed-login
       escalation naming the config dir.
    3. **Refresh quota.** A Claude account that now backs the quota poller gets
       an immediate poll, off the caller's process, so `arb quota` is fresh.

  Every outcome writes an `Arbiter.Accounts.LoginRecord` with a short
  fingerprint of the credential file's mtime and size — never its contents.

  Options: `:outcome` (default `:succeeded`), `:reason`, and the `:quota_refresh`
  test seam, `fun/1` given the account id.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.LoginRecord
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Agents
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Alerts
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Quota

  require Logger

  @alert_sources [:worker_report, :usage_poll, :periodic_probe]
  @account_providers [:claude, :codex, :antigravity]

  @type info :: %{
          required(:provider) => atom(),
          required(:account) => String.t(),
          required(:config_dir) => String.t(),
          optional(:login_id) => String.t(),
          optional(:started_by) => String.t() | nil,
          optional(:started_at) => DateTime.t()
        }

  @spec complete(info(), keyword()) :: {:ok, %{credential: atom(), fingerprint: String.t() | nil}}
  def complete(%{provider: provider, account: slug, config_dir: dir} = info, opts \\ []) do
    outcome = Keyword.get(opts, :outcome, :succeeded)
    credential_file = credential_file(provider, dir)

    {credential, account} =
      if outcome == :succeeded, do: reference(provider, slug, credential_file), else: {:none, nil}

    if outcome == :succeeded do
      clear_alerts(provider, dir)
      refresh_quota(provider, account, credential, opts)
    end

    fingerprint = if outcome == :succeeded, do: fingerprint(credential_file)

    record(info, outcome, Keyword.get(opts, :reason), fingerprint, account)
    {:ok, %{credential: credential, fingerprint: fingerprint}}
  end

  @doc """
  Short non-secret fingerprint of the file at `path`: 12 hex characters of a
  SHA-256 over its mtime and size. `nil` when it cannot be statted.
  """
  @spec fingerprint(String.t() | nil) :: String.t() | nil
  def fingerprint(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} ->
        :sha256
        |> :crypto.hash("#{mtime}:#{size}")
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      {:error, _} ->
        nil
    end
  end

  def fingerprint(_), do: nil

  defp credential_file(provider, dir) do
    case LoginRecipes.fetch(provider) do
      {:ok, %{credential_path: rel}} when is_binary(rel) -> Path.join(dir, rel)
      _ -> nil
    end
  end

  # -- credential --------------------------------------------------------------

  defp reference(provider, slug, file) when provider in @account_providers do
    with {:ok, account} <- ensure_account(provider, slug),
         true <- provider == :claude and is_binary(file),
         {:ok, _credential} <- Accounts.reference_credential_path(account, file) do
      {:referenced, account}
    else
      false ->
        {:unsupported, account_or_nil(provider, slug)}

      {:error, reason} ->
        Logger.warning(
          "login #{provider}-#{slug}: recording the credential failed: #{inspect(reason)}"
        )

        {:error, account_or_nil(provider, slug)}
    end
  end

  defp reference(_provider, _slug, _file), do: {:unsupported, nil}

  defp ensure_account(provider, slug) do
    case Accounts.get_account("#{provider}:#{slug}") do
      {:ok, account} -> {:ok, account}
      {:error, :not_found} -> Accounts.create_account(%{provider: provider, slug: slug})
      {:error, _} = error -> error
    end
  end

  defp account_or_nil(provider, slug) do
    case Accounts.get_account("#{provider}:#{slug}") do
      {:ok, %ProviderAccount{} = account} -> account
      _ -> nil
    end
  end

  # -- alerts ------------------------------------------------------------------

  defp clear_alerts(provider, dir) do
    case Map.fetch(Agents.adapters(), provider) do
      {:ok, adapter} ->
        for source <- @alert_sources do
          _ = Alerts.clear(:credential_expired, "#{inspect(adapter)}:#{source}")
        end

        CredentialWatchdog.clear(adapter)

      :error ->
        :ok
    end

    if provider == :claude, do: CoordinatorNotifier.quota_grant_restored(dir)
    :ok
  rescue
    e -> Logger.warning("login #{provider}: clearing alerts raised: #{Exception.message(e)}")
  end

  # -- quota -------------------------------------------------------------------

  defp refresh_quota(:claude, %ProviderAccount{id: id}, :referenced, opts) do
    fun = Keyword.get(opts, :quota_refresh, &default_quota_refresh/1)

    # Off the runner's process: a poll is a network call and must not delay
    # the terminal broadcast.
    Task.start(fn ->
      try do
        fun.(id)
      rescue
        e -> Logger.warning("login quota refresh raised: #{Exception.message(e)}")
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp refresh_quota(_provider, _account, _credential, _opts), do: :ok

  defp default_quota_refresh(account_id), do: Quota.capture_oauth_usage(account_id, [])

  # -- history -----------------------------------------------------------------

  defp record(info, outcome, reason, fingerprint, account) do
    now = DateTime.utc_now()

    attrs = %{
      login_id: Map.get(info, :login_id),
      provider: info.provider,
      account: info.account,
      provider_account_id: account && account.id,
      started_by: Map.get(info, :started_by),
      started_at: Map.get(info, :started_at) || now,
      ended_at: now,
      outcome: outcome,
      reason: reason,
      fingerprint: fingerprint
    }

    case Ash.create(LoginRecord, attrs) do
      {:ok, record} ->
        record

      {:error, error} ->
        Logger.warning(
          "login #{info.provider}-#{info.account}: history not recorded: #{inspect(error)}"
        )

        nil
    end
  end
end
