defmodule Arbiter.Accounts.AdmissionMode do
  @moduledoc """
  The effective `scheduler_admission` mode of one provider account (O11,
  bd-di40xs; `docs/design/provider-dynamic-concurrency.md` §10.1).

  The installation-wide key (`Arbiter.Settings.scheduler_admission/0`) stays the
  default. An account may carry its own `admission` override (`legacy`,
  `shadow` or `enforce`); unset, it follows the key. The budget is per
  `(account, pool)`, so accounts in different modes are coherent: one trials
  `enforce` while another stays in `shadow`. Node-layer caps are unaffected —
  they are always enforced.

  `effective/2` says where the mode came from (`:account` or `:installation`),
  which the status surfaces show. Nothing here raises: an unreadable key reads
  `:legacy`, an unreadable account table reads as no overrides.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount

  @type mode :: :legacy | :shadow | :enforce
  @type source :: :account | :installation
  @type effective :: %{mode: mode(), source: source()}

  @rank %{legacy: 0, shadow: 1, enforce: 2}

  @doc """
  The effective mode of `account` (a `ProviderAccount`, or `nil` for a pool
  with no account behind it) and its source. `install` is the installation key,
  read when not given.
  """
  @spec effective(ProviderAccount.t() | nil, mode() | nil) :: effective()
  def effective(account, install \\ nil) do
    case account do
      %{admission: mode} when mode in [:legacy, :shadow, :enforce] ->
        %{mode: mode, source: :account}

      _ ->
        %{mode: install || installation(), source: :installation}
    end
  end

  @doc "Just the mode of `effective/2`."
  @spec mode(ProviderAccount.t() | nil, mode() | nil) :: mode()
  def mode(account, install \\ nil), do: effective(account, install).mode

  @doc "The installation-wide key; `:legacy` when it cannot be read."
  @spec installation() :: mode()
  def installation do
    Arbiter.Settings.scheduler_admission()
  rescue
    _ -> :legacy
  catch
    :exit, _ -> :legacy
  end

  @doc """
  The strictest mode in force anywhere: the installation key or any account's
  override, `enforce` over `shadow` over `legacy`. The scheduler walk is planned
  when this is `shadow` or `enforce`, so an account trialling a mode under a
  `legacy` installation still gets a walk; each account's own effective mode
  then decides what that walk means for it.
  """
  @spec walk_mode() :: mode()
  def walk_mode do
    Enum.max_by([installation() | override_modes()], &Map.fetch!(@rank, &1))
  end

  defp override_modes do
    ProviderAccount
    |> Ash.Query.filter(not is_nil(admission) and is_nil(deleted_at))
    |> Ash.read!()
    |> Enum.map(& &1.admission)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
