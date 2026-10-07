defmodule Arbiter.Usage.Params do
  @moduledoc """
  Argument coercion for the usage reads that REST (`ArbiterWeb.Api.UsageController`)
  and MCP (`usage_events_list`, `usage_calibration`, the `account` arg of
  `usage_summarize`) share. Every function answers `{:ok, value}` or
  `{:error, {:invalid, message}}`; REST maps the latter through
  `Arbiter.Params.to_rest/1`.
  """

  alias Arbiter.Accounts
  alias Arbiter.Usage.Event

  @default_event_limit 50
  @max_event_limit 1000

  @doc "Default row count of `Arbiter.Usage.Events.list/1`."
  @spec default_event_limit() :: pos_integer()
  def default_event_limit, do: @default_event_limit

  @doc "Largest accepted `limit` for a raw event list."
  @spec max_event_limit() :: pos_integer()
  def max_event_limit, do: @max_event_limit

  @doc "A usage-event `step`; blank is `nil`."
  @spec step(term()) :: {:ok, atom() | nil} | {:error, {:invalid, String.t()}}
  def step(raw), do: enum(raw, Event.steps(), "step")

  @doc "A usage-event `source`; blank is `nil`."
  @spec source(term()) :: {:ok, atom() | nil} | {:error, {:invalid, String.t()}}
  def source(raw), do: enum(raw, Event.sources(), "source")

  @doc """
  An `account` ref (UUID, `provider:slug` or an unambiguous bare slug,
  `Arbiter.Accounts.get_account/1`) to the account id that
  `usage_events.provider_account_id` is filtered on. Blank is `nil`.
  """
  @spec account_id(term()) :: {:ok, String.t() | nil} | {:error, {:invalid, String.t()}}
  def account_id(raw) when raw in [nil, ""], do: {:ok, nil}

  def account_id(ref) when is_binary(ref) do
    case Accounts.get_account(ref) do
      {:ok, account} ->
        {:ok, account.id}

      {:error, :not_found} ->
        {:error, {:invalid, "account #{inspect(ref)} not found"}}

      {:error, :ambiguous} ->
        {:error, {:invalid, "account #{inspect(ref)} is ambiguous; use \"provider:slug\""}}
    end
  end

  def account_id(_), do: {:error, {:invalid, "account must be a string"}}

  @doc "The raw-event `limit`: positive, default #{@default_event_limit}, clamped to #{@max_event_limit}."
  @spec event_limit(term()) :: {:ok, pos_integer()} | {:error, {:invalid, String.t()}}
  def event_limit(raw), do: Arbiter.Params.limit(raw, @default_event_limit, @max_event_limit)

  @doc "A calibration `window_days`: a positive integer; blank is `nil` (the report default)."
  @spec window_days(term()) :: {:ok, pos_integer() | nil} | {:error, {:invalid, String.t()}}
  def window_days(raw) when raw in [nil, ""], do: {:ok, nil}

  def window_days(raw) do
    case Arbiter.Params.integer(raw) do
      {:ok, n} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid, "window_days must be a positive integer"}}
    end
  end

  defp enum(raw, _allowed, _name) when raw in [nil, ""], do: {:ok, nil}

  defp enum(raw, allowed, name) when is_binary(raw) do
    case Enum.find(allowed, &(Atom.to_string(&1) == raw)) do
      nil -> {:error, {:invalid, "invalid #{name}: #{inspect(raw)}"}}
      atom -> {:ok, atom}
    end
  end

  defp enum(raw, allowed, name) when is_atom(raw), do: enum(Atom.to_string(raw), allowed, name)
  defp enum(raw, _allowed, name), do: {:error, {:invalid, "invalid #{name}: #{inspect(raw)}"}}
end
