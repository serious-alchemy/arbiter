defmodule Arbiter.Providers.Pause do
  @moduledoc """
  Pause and resume per provider and per provider account (bd-5ef587) — the
  operator's one-command safety stop, mirroring `arb scheduler pause`.

  A pause is persisted on the installation settings row
  (`Arbiter.Settings.provider_pauses/0`) as `%{target => entry}`:

    * `"claude"` / `"codex"` / `"antigravity"` — every account on the provider
      (and, through `provider_paused?/1`, the account-less legacy routing);
    * `"account:<uuid>"` — one account.

  `entry` is `%{"reason", "by", "at"}` — who, when and why, the audit trail.

  Every router consults `for_account/1` and drops a paused candidate with the
  reason `paused`: `ProviderRouting`, `ReviewerRouting`, the `ProviderPool`
  failover (`Arbiter.Agents.ProviderPool`) and `Arbiter.Agents.provider_available?/1`
  (resume, fix and conflict passes). Running workers are not touched here.

  `pause/2` and `resume/2` broadcast `provider_paused` / `provider_resumed` on
  the `"system"` event stream.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Settings

  require Ash.Query

  @providers ~w(claude codex antigravity)

  @type entry :: %{
          target: String.t(),
          reason: String.t() | nil,
          by: String.t() | nil,
          actor: String.t() | nil,
          at: DateTime.t() | nil
        }

  @doc "Every active pause, oldest first."
  @spec list() :: [entry()]
  def list do
    Settings.provider_pauses()
    |> Enum.map(fn {target, e} -> to_entry(target, e) end)
    |> Enum.sort_by(&(&1.at && DateTime.to_unix(&1.at)), :asc)
  end

  @doc "The pause that applies to `account` (its own, else its provider's), or `nil`."
  @spec for_account(ProviderAccount.t()) :: entry() | nil
  def for_account(%ProviderAccount{id: id, provider: provider}) do
    pauses = Settings.provider_pauses()
    lookup(pauses, "account:#{id}") || lookup(pauses, Atom.to_string(provider))
  end

  @doc "The provider-wide pause for a provider / agent type atom, or `nil`."
  @spec for_provider(atom() | String.t() | nil) :: entry() | nil
  def for_provider(provider) do
    case normalize(provider) do
      nil -> nil
      code -> lookup(Settings.provider_pauses(), code)
    end
  end

  @doc """
  The pause that blocks `provider` for workspace `ws_id`: its provider-wide
  pause, else the pause on the account the workspace meters it under. Fails
  open (`nil`) when the account cannot be resolved.
  """
  @spec blocking(atom() | String.t() | nil, String.t() | nil) :: entry() | nil
  def blocking(provider, ws_id) do
    for_provider(provider) || account_pause(provider, ws_id)
  end

  defp account_pause(provider, ws_id) when is_binary(ws_id) and not is_nil(provider) do
    atom = if is_binary(provider), do: String.to_existing_atom(provider), else: provider

    case Arbiter.Accounts.Resolver.get(Arbiter.Quota.account_id(ws_id, atom)) do
      %ProviderAccount{} = account -> for_account(account)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp account_pause(_provider, _ws_id), do: nil

  @spec provider_paused?(atom() | String.t() | nil) :: boolean()
  def provider_paused?(provider), do: for_provider(provider) != nil

  @doc "The `held — <provider> paused: <reason>` phrase for a provider-wide pause."
  @spec hold_phrase(atom() | String.t()) :: String.t() | nil
  def hold_phrase(provider) do
    case for_provider(provider) do
      nil -> nil
      e -> "held — #{normalize(provider)} paused: #{e.reason || "no reason given"}"
    end
  end

  @doc "Pause `ref` (a provider, an account id, `provider:slug` or a bare slug)."
  @spec pause(String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def pause(ref, opts \\ []) do
    by = Keyword.get(opts, :by)
    reason = Keyword.get(opts, :reason)

    with {:ok, target, label} <- resolve(ref) do
      entry = %{
        "reason" => reason,
        "by" => by,
        # bd-6i7yzq: `by` is the surface ("mcp", "api", "dashboard"); `actor` is
        # who was acting there (`Arbiter.Actor` label), when known.
        "actor" => Arbiter.Actor.resolve_label(nil),
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      with {:ok, _} <-
             Settings.set_provider_pauses(Map.put(Settings.provider_pauses(), target, entry)) do
        result = to_entry(target, entry)
        broadcast("provider_paused", result, label)
        {:ok, result}
      end
    end
  end

  @doc """
  Pause `ref` and, when `stop_running?`, stop the live workers on it. The one
  sequence behind REST and MCP. Returns `{:ok, stopped_task_ids}`.
  """
  @spec pause_and_stop(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def pause_and_stop(ref, opts \\ []) do
    {stop?, opts} = Keyword.pop(opts, :stop_running, false)

    with {:ok, _entry} <- pause(ref, opts) do
      {:ok, if(stop?, do: stop_running(ref), else: [])}
    end
  end

  @doc """
  The `by` string for a pause/resume: the token's actor label and the surface
  (`"coordinator via mcp"`), or just the surface when the caller has no scope.
  Never caller-asserted.
  """
  @spec attribution(String.t() | nil, String.t()) :: String.t()
  def attribution(nil, surface), do: surface
  def attribution(label, surface), do: "#{label} via #{surface}"

  @doc """
  The one error table for pause/resume failures: `{kind, message}` with
  `kind` in `:not_found | :invalid | :internal`.
  """
  @spec error_message(term(), String.t()) :: {:not_found | :invalid | :internal, String.t()}
  def error_message(:not_found, ref), do: {:not_found, "no provider or account matches `#{ref}`"}

  def error_message(:ambiguous, ref),
    do: {:invalid, "`#{ref}` matches several accounts — use provider:slug"}

  def error_message(:not_paused, ref), do: {:invalid, "`#{ref}` is not paused"}

  def error_message(other, ref),
    do: {:internal, "pause/resume of `#{ref}` failed: #{inspect(other)}"}

  @doc "Resume `ref`; `{:error, :not_paused}` when it was not paused."
  @spec resume(String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def resume(ref, opts \\ []) do
    with {:ok, target, label} <- resolve(ref) do
      pauses = Settings.provider_pauses()

      case Map.pop(pauses, target) do
        {nil, _} ->
          {:error, :not_paused}

        {entry, rest} ->
          with {:ok, _} <- Settings.set_provider_pauses(rest) do
            result = to_entry(target, entry)

            broadcast(
              "provider_resumed",
              Map.put(result, :resumed_by, Keyword.get(opts, :by)),
              label
            )

            {:ok, result}
          end
      end
    end
  end

  @doc """
  Stop the live workers running on a paused target (`arb provider pause
  --stop-running`). Pausing never does this by itself. Returns the task ids
  that were stopped.
  """
  @spec stop_running(String.t()) :: [String.t()]
  def stop_running(ref) do
    case resolve(ref) do
      {:ok, target, _label} ->
        Arbiter.Workers.Run
        |> Ash.Query.filter(is_nil(completed_at) and not is_nil(task_id))
        |> Ash.read!()
        |> Enum.filter(&run_on_target?(&1, target))
        |> Enum.map(& &1.task_id)
        |> Enum.uniq()
        |> Enum.filter(&(Arbiter.Worker.whereis(&1) != nil and stopped?(&1)))

      _ ->
        []
    end
  end

  defp stopped?(task_id), do: Arbiter.Worker.stop(task_id, :normal, 10_000) == :ok

  defp run_on_target?(run, "account:" <> id), do: run.provider_account_id == id
  defp run_on_target?(run, code), do: normalize(run.provider) == code

  @doc "JSON-friendly view of `list/0`."
  @spec to_json([entry()] | nil) :: [map()]
  def to_json(entries \\ nil) do
    Enum.map(entries || list(), fn e ->
      %{
        "target" => e.target,
        "label" => label(e.target),
        "reason" => e.reason,
        "by" => e.by,
        "actor" => e.actor,
        "at" => e.at && DateTime.to_iso8601(e.at)
      }
    end)
  end

  @doc "Human label for a stored target (`account:<id>` → `provider:slug`)."
  @spec label(String.t()) :: String.t()
  def label("account:" <> id) do
    case Accounts.get_account(id) do
      {:ok, a} -> "#{a.provider}:#{a.slug}"
      _ -> "account #{id}"
    end
  end

  def label(target), do: target

  @doc "Provider code (`claude`/`codex`/`antigravity`) for an atom or agent type; `gemini` is antigravity."
  @spec normalize(atom() | String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil
  def normalize(p) when is_atom(p), do: normalize(Atom.to_string(p))
  def normalize("gemini"), do: "antigravity"
  def normalize(p) when p in @providers, do: p
  def normalize(_), do: nil

  # ---- internals -----------------------------------------------------------

  defp resolve(ref) when is_binary(ref) do
    case normalize(ref) do
      nil ->
        case Accounts.get_account(ref) do
          {:ok, a} -> {:ok, "account:#{a.id}", "#{a.provider}:#{a.slug}"}
          {:error, _} = err -> err
        end

      code ->
        {:ok, code, code}
    end
  end

  defp lookup(pauses, key) do
    case Map.get(pauses, key) do
      nil -> nil
      e -> to_entry(key, e)
    end
  end

  defp to_entry(target, e) do
    %{
      target: target,
      reason: e["reason"],
      by: e["by"],
      actor: e["actor"],
      at: parse_at(e["at"])
    }
  end

  defp parse_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_at(_), do: nil

  defp broadcast(topic, entry, label) do
    Arbiter.Events.broadcast("system", topic, %{
      target: entry.target,
      label: label,
      reason: entry.reason,
      by: Map.get(entry, :resumed_by) || entry.by
    })
  end
end
