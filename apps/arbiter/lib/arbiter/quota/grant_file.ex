defmodule Arbiter.Quota.GrantFile do
  @moduledoc """
  Reads the quota poller's **dedicated Claude OAuth grant** (bd-b632tz): a
  `.credentials.json` a `claude` CLI login wrote into its own
  `CLAUDE_CONFIG_DIR` (conventionally `~/.arbiter/quota-claude`), which an
  account references by path through a `:cli_credentials_path`
  `Arbiter.Accounts.ProviderCredential`.

  Arbiter never stores this grant's tokens. `read/1` opens the file fresh on
  every call — `Arbiter.Quota` authenticates each `/api/oauth/usage` poll with
  whatever access token the file holds *now*, and
  `Arbiter.Quota.GrantRefresher` reads the expiries to decide when to let the
  CLI refresh it. Both only ever read: the CLI is the file's only writer, so
  its refresh-token rotation never races an Arbiter write (the bd-6umoh9
  hazard was a *copy* of a grant being refreshed behind the original's back).

  The struct hides both tokens from `inspect/1`, so a grant that ends up in
  a log line or a crash report never leaks them.
  """

  @derive {Inspect, only: [:path, :expires_at, :refresh_token_expires_at]}
  @enforce_keys [:path, :access_token]
  defstruct [:path, :access_token, :expires_at, :refresh_token_expires_at]

  @type t :: %__MODULE__{
          path: String.t(),
          access_token: String.t(),
          expires_at: DateTime.t() | nil,
          refresh_token_expires_at: DateTime.t() | nil
        }

  @filename ".credentials.json"

  @doc """
  Read the grant at `path`. `{:error, :no_access_token}` when the file parses
  but carries no `claudeAiOauth.accessToken` (a logged-out config dir);
  `{:error, :malformed}` for unparseable JSON; otherwise the `File.read/1`
  reason (`:enoent`, `:eacces`, …).
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, atom()}
  def read(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, oauth} <- decode(content),
         {:ok, token} <- access_token(oauth) do
      {:ok,
       %__MODULE__{
         path: path,
         access_token: token,
         expires_at: from_ms(oauth["expiresAt"]),
         refresh_token_expires_at: from_ms(oauth["refreshTokenExpiresAt"])
       }}
    end
  end

  @doc """
  Normalize an operator-supplied location to the absolute path of a readable
  grant: `~` and relative segments are expanded, and a config directory
  resolves to the `#{@filename}` inside it. Any other filename is refused —
  the CLI only ever refreshes `$CLAUDE_CONFIG_DIR/#{@filename}`, so a grant
  stored under another name would silently never renew.
  """
  @spec normalize_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def normalize_path(location) when is_binary(location) do
    expanded = Path.expand(location)

    path =
      if File.dir?(expanded), do: Path.join(expanded, @filename), else: expanded

    cond do
      not File.exists?(path) -> {:error, :enoent}
      Path.basename(path) != @filename -> {:error, :not_a_credentials_file}
      true -> with {:ok, _grant} <- read(path), do: {:ok, path}
    end
  end

  @doc "The `CLAUDE_CONFIG_DIR` the CLI reads and refreshes `path` under."
  @spec config_dir(String.t()) :: String.t()
  def config_dir(path) when is_binary(path), do: Path.dirname(path)

  defp decode(content) do
    case Jason.decode(content) do
      {:ok, %{"claudeAiOauth" => oauth}} when is_map(oauth) -> {:ok, oauth}
      {:ok, %{}} -> {:error, :no_access_token}
      _ -> {:error, :malformed}
    end
  end

  defp access_token(%{"accessToken" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp access_token(_oauth), do: {:error, :no_access_token}

  defp from_ms(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp from_ms(_), do: nil
end
