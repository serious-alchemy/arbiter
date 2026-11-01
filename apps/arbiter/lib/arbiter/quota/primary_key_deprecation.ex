defmodule Arbiter.Quota.PrimaryKeyDeprecation do
  @moduledoc """
  One-time boot warning for quota keys that only govern a provider's primary
  (5h/session) window (5H C10, bd-138qku).

  Anthropic retired the 5h window, so for Claude these keys are inert: the 7d
  window is the gate. They still validate and are stored unchanged (no
  migration); this module only tells the operator they do nothing for Claude.
  Codex and Antigravity keep a real primary window, so their accounts are not
  reported.
  """

  require Logger

  @primary_atoms [
    {"throttle_threshold", :throttle_threshold},
    {"paced_floor", :paced_floor},
    {"pace_exempt_threshold", :pace_exempt_threshold}
  ]
  @primary_keys Enum.map(@primary_atoms, &elem(&1, 0))

  @doc "The quota keys that only govern the primary (5h/session) window."
  @spec primary_keys() :: [String.t()]
  def primary_keys, do: @primary_keys

  @doc """
  Find inert primary-class keys. Sources default to the live DB / app env and
  can be injected with `:accounts`, `:workspaces`, `:app_env`. Returns
  `[{source_label, key}]`.
  """
  @spec find(keyword()) :: [{String.t(), String.t()}]
  def find(opts \\ []) do
    accounts = Keyword.get_lazy(opts, :accounts, &load_accounts/0)
    workspaces = Keyword.get_lazy(opts, :workspaces, &load_workspaces/0)

    app_env =
      Keyword.get_lazy(opts, :app_env, fn -> Application.get_env(:arbiter, :quota, []) end)

    account_hits =
      for %{provider: :claude} = a <- accounts,
          key <- keys_in(a.quota_config),
          do: {"account claude:#{a.slug}", key}

    workspace_hits =
      for w <- workspaces,
          key <- keys_in(get_in_map(w.config, "quota")),
          do: {"workspace #{w.name}", key}

    env_hits =
      for {key, atom} <- @primary_atoms,
          overridden?(app_env, atom),
          do: {"app env :quota", key}

    account_hits ++ workspace_hits ++ env_hits
  end

  @doc "Log a single warning when any inert key is set. Never raises."
  @spec warn_at_boot(keyword()) :: :ok
  def warn_at_boot(opts \\ []) do
    case find(opts) do
      [] ->
        :ok

      hits ->
        listing = Enum.map_join(hits, "; ", fn {src, key} -> "#{src}: #{key}" end)

        Logger.warning(
          "Claude no longer has a 5h window, so these primary-window quota keys have no " <>
            "effect for Claude (the 7d gate binds; weekly_* keys still apply): #{listing}. " <>
            "They still validate and may be left in place or removed. See docs/quota-and-auth.md."
        )
    end
  rescue
    _ -> :ok
  end

  # config/config.exs ships `throttle_threshold: 0.85`; only a different value
  # is an operator override worth warning about.
  defp overridden?(app_env, :throttle_threshold),
    do: match?({:ok, v} when v != 0.85, Keyword.fetch(app_env, :throttle_threshold))

  defp overridden?(app_env, key), do: Keyword.has_key?(app_env, key)

  defp keys_in(map)
       when is_map(map), do: Enum.filter(@primary_keys, &Map.has_key?(map, &1))

  defp keys_in(_), do: []

  defp get_in_map(map, key) when is_map(map), do: Map.get(map, key)
  defp get_in_map(_, _), do: nil

  defp load_accounts, do: Arbiter.Accounts.list_accounts()

  defp load_workspaces do
    case Ash.read(Arbiter.Tasks.Workspace) do
      {:ok, ws} -> ws
      _ -> []
    end
  end
end
