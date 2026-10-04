defmodule Arbiter.Accounts.Logins do
  @moduledoc """
  The operator-facing side of the login relay (login relay 6/6, bd-bh50vs, epic
  bd-dqvv90): the one place the Providers page (`ArbiterWeb.ProvidersLive`) and
  `arb account login` (`ArbiterWeb.Api.AccountLoginController`) start, watch,
  answer and cancel a `Arbiter.Accounts.LoginRunner`, and read the Login
  history (`Arbiter.Accounts.LoginRecord`).

  `status/1` answers for a login that is gone too: the runner stops after its
  terminal state, so a poller that was between two polls still gets the
  outcome, from the history row the completion step wrote.

  ## Test seam

  `config :arbiter, :login_start_opts` — a keyword list, or a `provider ->
  keyword` function — is merged into every `start/2`, so a test can aim the
  runner at a fake CLI and a direct tmux runner. Unset in production.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.LoginRecord
  alias Arbiter.Accounts.LoginRunner

  require Ash.Query

  @history_limit 5

  @type result :: map()

  @doc """
  Start a login for the account `ref` (uuid, `provider:slug` or bare slug).
  Options: `:started_by` (who is asking), `:topic` (a private PubSub topic for
  `{:login_state, id, snapshot}` pushes).
  """
  @spec start(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(ref, opts \\ []) when is_binary(ref) do
    with {:ok, account} <- Accounts.get_account(ref) do
      LoginRunner.start_login(
        Keyword.merge(
          [provider: account.provider, account: account.slug],
          Keyword.merge(seam(account.provider), opts)
        )
      )
    end
  end

  @doc """
  The login's current state: the live snapshot, or — once the runner is gone —
  the outcome recorded in the history (`status` is the outcome, `reason` the
  short reason). `{:error, :not_found}` for an id that never existed.
  """
  @spec status(String.t()) :: {:ok, result()} | {:error, :not_found}
  def status(login_id) when is_binary(login_id) do
    case LoginRunner.state(login_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :not_found} -> recorded(login_id)
    end
  end

  defdelegate relay_paste(login_id, text), to: LoginRunner
  defdelegate cancel(login_id), to: LoginRunner

  @doc "The most recent logins for an account, newest first."
  @spec history(atom(), String.t(), pos_integer()) :: [LoginRecord.t()]
  def history(provider, slug, limit \\ @history_limit) do
    LoginRecord
    |> Ash.Query.filter(provider == ^provider and account == ^slug)
    |> Ash.Query.sort(ended_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  end

  @doc "One history row by id, with its redacted transcript."
  @spec get_record(String.t()) :: {:ok, LoginRecord.t()} | {:error, :not_found}
  def get_record(id) do
    case Ash.get(LoginRecord, id) do
      {:ok, %LoginRecord{} = record} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp recorded(login_id) do
    LoginRecord
    |> Ash.Query.filter(login_id == ^login_id)
    |> Ash.read_one()
    |> case do
      {:ok, %LoginRecord{} = record} ->
        {:ok,
         %{
           id: login_id,
           provider: record.provider,
           account: record.account,
           status: record.outcome,
           url: nil,
           device_code: nil,
           needs_paste?: false,
           reason: record.reason,
           session_id: nil
         }}

      _ ->
        {:error, :not_found}
    end
  end

  defp seam(provider) do
    case Application.get_env(:arbiter, :login_start_opts, []) do
      fun when is_function(fun, 1) -> fun.(provider)
      opts when is_list(opts) -> opts
    end
  end
end
