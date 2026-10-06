defmodule Arbiter.Grok.CredentialStore do
  @moduledoc """
  The canonical grok OIDC credential: one `auth.json` (the grok provider
  account's, see `resolve/1`) that only `Arbiter.Grok.CredentialBroker` ever
  refreshes (bd-9p4lx9).

  grok's `auth.json` is a map of `"<issuer>::<client id>"` to one entry, which
  carries the access token (`key`), its `expires_at`, and a **rotating**
  `refresh_token` plus `oidc_issuer` / `oidc_client_id`. This module reads the
  OIDC entry and writes a refresh result back, and nothing else:

    * `read/1` never creates, modifies or deletes the file.
    * `persist/3` rewrites it atomically (temp file in the same directory,
      mode `0600` before any byte is written, then `rename/2`), changes only
      the three token fields and leaves every other field and entry as it
      found them. A failed write leaves the previous file in place.
    * Nothing here deletes `auth.json`. grok deletes it on a permanent refresh
      failure; Arbiter never does.

  Token values never appear in a log line or an error tuple from this module.
  `fingerprint/1` is the only thing derived from a secret that may be logged
  or compared: a 12-hex-digit SHA-256 prefix.
  """

  require Logger

  @type creds :: %{
          entry_key: String.t(),
          access_token: String.t() | nil,
          refresh_token: String.t(),
          expires_at: DateTime.t() | nil,
          issuer: String.t(),
          client_id: String.t() | nil
        }

  @type rotated :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: DateTime.t()
        }

  @default_path "~/.grok/auth.json"

  @doc "The default canonical path (`~/.grok/auth.json`, expanded)."
  @spec default_path() :: String.t()
  def default_path, do: Path.expand(@default_path)

  @type path_source :: :explicit | :account | :fallback

  @doc """
  The canonical `auth.json` path, and where it came from (bd-8rvkqd).

  There is exactly **one** canonical credential, and the dashboard login relay
  (`Arbiter.Accounts.LoginRunner`, `GROK_HOME=<accounts_root>/grok-<slug>`)
  writes it, so that is the file the broker refreshes and the doctor reports:

    1. `:explicit` - `:auth_path` in `opts`, else
       `config :arbiter, :grok_broker, auth_path:` (an operator pin, and what
       tests use).
    2. `:account` - `<accounts_root>/grok-<slug>/auth.json` of the grok provider
       account. With several accounts the one slugged `"default"` wins, else
       the first whose file exists, else the first by slug.
    3. `:fallback` - `~/.grok/auth.json`, only when no grok account exists.

  Nothing is copied between locations: the refresh token rotates on every
  refresh, so two copies would race. Resolution is cheap, so the broker repeats
  it per request and picks up an account created by a first login without a
  restart.

  Other options: `:accounts` (a list of `ProviderAccount`s, or a 0-arity fun
  returning one; default `Arbiter.Accounts.list_accounts(provider: :grok)`),
  `:accounts_root`.
  """
  @spec resolve(keyword()) :: {String.t(), path_source()}
  def resolve(opts \\ []) do
    case explicit_path(opts) do
      path when is_binary(path) ->
        {Path.expand(path), :explicit}

      nil ->
        case account_path(opts) do
          nil -> {default_path(), :fallback}
          path -> {path, :account}
        end
    end
  end

  @doc "`resolve/1` without the source."
  @spec resolve_path(keyword()) :: String.t()
  def resolve_path(opts \\ []), do: opts |> resolve() |> elem(0)

  defp explicit_path(opts) do
    path =
      Keyword.get_lazy(opts, :auth_path, fn ->
        :arbiter |> Application.get_env(:grok_broker, []) |> Keyword.get(:auth_path)
      end)

    if is_binary(path) and path != "", do: path
  end

  defp account_path(opts) do
    accounts =
      case Keyword.get(opts, :accounts) do
        list when is_list(list) -> list
        fun when is_function(fun, 0) -> fun.()
        nil -> grok_accounts()
      end

    root = Keyword.get_lazy(opts, :accounts_root, &Arbiter.Config.Paths.accounts_root/0)

    paths =
      accounts
      |> Enum.sort_by(&(&1.slug != "default"))
      |> Enum.map(&Path.expand(Path.join([root, "#{&1.provider}-#{&1.slug}", "auth.json"])))

    Enum.find(paths, &File.regular?/1) || List.first(paths)
  end

  defp grok_accounts do
    Arbiter.Accounts.list_accounts(provider: :grok)
  rescue
    error ->
      Logger.warning(
        "grok credential path: could not list grok provider accounts " <>
          "(#{Exception.message(error)}); using #{@default_path}"
      )

      []
  catch
    :exit, _ -> []
  end

  @doc """
  Read the OIDC entry from `path`. `{:error, :not_logged_in}` for a missing,
  unparseable or entry-less file, or an entry with no refresh token (an API-key
  or external-provider login has nothing to refresh).
  """
  @spec read(String.t()) :: {:ok, creds()} | {:error, :not_logged_in}
  def read(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = doc} <- Jason.decode(raw),
         {entry_key, %{} = entry} <- oidc_entry(doc),
         refresh when is_binary(refresh) and refresh != "" <- entry["refresh_token"] do
      {:ok,
       %{
         entry_key: entry_key,
         access_token: string_or_nil(entry["key"]),
         refresh_token: refresh,
         expires_at: parse_time(entry["expires_at"]),
         issuer: string_or_nil(entry["oidc_issuer"]) || issuer_from_key(entry_key),
         client_id: string_or_nil(entry["oidc_client_id"])
       }}
    else
      _ -> {:error, :not_logged_in}
    end
  end

  @doc """
  Write a refresh result over `creds`' entry in `path`. Re-reads the file just
  before writing so any other entry or field written since is preserved.
  """
  @spec persist(String.t(), creds(), rotated()) :: :ok | {:error, term()}
  def persist(path, %{entry_key: entry_key}, %{} = rotated) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = doc} <- Jason.decode(raw),
         %{} = entry <- Map.get(doc, entry_key) do
      entry =
        Map.merge(entry, %{
          "key" => rotated.access_token,
          "refresh_token" => rotated.refresh_token,
          "expires_at" => DateTime.to_iso8601(rotated.expires_at)
        })

      write_atomic(path, Jason.encode!(Map.put(doc, entry_key, entry)))
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :entry_gone}
    end
  end

  @doc "A loggable 12-hex-digit identity for a secret; not reversible."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(secret) when is_binary(secret) do
    :sha256 |> :crypto.hash(secret) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # ---- internals ------------------------------------------------------------

  defp oidc_entry(doc) do
    Enum.find(doc, fn
      {_key, %{"auth_mode" => "oidc"}} -> true
      {_key, %{"refresh_token" => token}} when is_binary(token) -> true
      _ -> false
    end)
  end

  defp write_atomic(path, body) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, "", [:write]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp issuer_from_key(entry_key), do: entry_key |> String.split("::", parts: 2) |> hd()

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
