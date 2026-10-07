defmodule Arbiter.Accounts.Fields do
  @moduledoc """
  The one registry of `Arbiter.Accounts.ProviderAccount` fields an operator can
  set (bd-1kr3qf, parity audit P-16).

  `POST /api/accounts`, `PATCH /api/accounts/:ref`, `arb account create|set`,
  the Providers page's create and Edit forms and the MCP `account_set` tool all
  take their field list, type coercion and validation from here, so a field
  cannot be editable on one surface and silently unreachable on another
  (D-A-14, D-A-15). Each entry says its `type`, whether a `nil` value
  `clearable?`-ly unsets it, and who may set it:

    * `phases` — `:create` (a new account), `:update` (an existing one);
    * `mcp?` — whether the coordinator-facing `account_set` tool may write it.

  `provider` and `slug` are the account's identity (§3.1): create-only, never
  editable. **Credentials are deliberately not in this registry.** A secret,
  a rotation or a login never rides on `create` / `update` / MCP; they have
  their own verbs (`Accounts.rotate_credential/2`, the login relay) and the
  parity manifest rules them `:intentional` off MCP.

  ## `quota_config`

  `quota_config` is itself a registry of keys (`quota_specs/0`), every one
  clearable and every one reachable from REST, CLI and the Edit form — nothing
  the gate reads from an account is writable only through `bin/arbiter eval`.
  `validate_quota_config/2` is the single validator: `:set` for a create,
  `:patch` for an update (where `nil` names a key to clear). `window_seconds`
  is written as a whole table (label => seconds), replacing the previous one.

  `cast/2` is the entry point for the non-secret attribute fields. It returns
  the attribute changes keyed by atom, validated in full, so a caller can
  perform one write or none.
  """

  alias Arbiter.Quota.Gate

  @type phase :: :create | :update
  @type spec :: %{
          name: String.t(),
          type: atom(),
          clearable?: boolean(),
          phases: [phase()],
          mcp?: boolean(),
          doc: String.t()
        }

  @identity ~w(provider slug)

  @fields [
    %{
      name: "provider",
      type: :provider,
      clearable?: false,
      phases: [:create],
      mcp?: false,
      doc: "claude | codex | antigravity | grok. The account's identity; never edited."
    },
    %{
      name: "slug",
      type: :text,
      clearable?: false,
      phases: [:create],
      mcp?: false,
      doc: "Operator handle, unique per provider. The account's identity; never edited."
    },
    %{
      name: "label",
      type: :text,
      clearable?: true,
      phases: [:create, :update],
      mcp?: true,
      doc: "Display name. Blank clears it."
    },
    %{
      name: "plan",
      type: :text,
      clearable?: true,
      phases: [:create, :update],
      mcp?: true,
      doc: "Plan name (max_5x, pro, ...). Blank clears it."
    },
    %{
      name: "enabled",
      type: :boolean,
      clearable?: false,
      phases: [:create, :update],
      mcp?: true,
      doc: "false parks the account without deleting it."
    },
    %{
      name: "max_concurrent",
      type: :count,
      clearable?: true,
      phases: [:create, :update],
      mcp?: true,
      doc: "Account concurrency ceiling. null / blank = no ceiling."
    },
    %{
      name: "provider_account_ref",
      type: :text,
      clearable?: true,
      phases: [:create],
      mcp?: false,
      doc: "The provider's own account uuid, when known (verification only)."
    },
    %{
      name: "provider_org_ref",
      type: :text,
      clearable?: true,
      phases: [:create],
      mcp?: false,
      doc: "The provider's own organization uuid, when known."
    },
    %{
      name: "quota_config",
      type: :quota_config,
      clearable?: false,
      phases: [:create, :update],
      mcp?: true,
      doc: "Account gate settings; see `quota_specs/0`. A null value clears that key."
    }
  ]

  @quota_specs [
    %{
      name: "threshold_mode",
      type: :mode,
      doc: "flat (a fixed ceiling) or paced (tracks the window)."
    },
    %{
      name: "throttle_threshold",
      type: :fraction,
      doc: "5-hour ceiling in (0, 1]; the account's floor for the 5h window."
    },
    %{
      name: "weekly_threshold",
      type: :fraction,
      doc: "7-day ceiling in (0, 1]; applies in flat mode."
    },
    %{
      name: "paced_floor",
      type: :fraction,
      doc: "5-hour paced floor in (0, 1]; applies in paced mode."
    },
    %{
      name: "weekly_paced_floor",
      type: :fraction,
      doc: "7-day paced floor in (0, 1]; applies in paced mode."
    },
    %{
      name: "weekly_warning_policy",
      type: :policy,
      doc: "ignore | hold: whether a provider weekly warning holds dispatch."
    },
    %{
      name: "window_seconds",
      type: :window_map,
      doc: "Quota window label => length in seconds (e.g. 5h => 18000); replaces the table."
    },
    %{
      name: "pace_exempt_priority",
      type: :priority,
      doc: "0..4: tickets of priority P0..Pn may run past the paced line. none = off."
    },
    %{
      name: "pace_exempt_threshold",
      type: :fraction,
      doc: "5-hour cap for exempt dispatches, in (0, 1]."
    },
    %{
      name: "weekly_pace_exempt_threshold",
      type: :fraction,
      doc: "7-day cap for exempt dispatches, in (0, 1]."
    }
  ]

  @quota_keys Enum.map(@quota_specs, & &1.name)
  @policies ~w(ignore hold)
  @off_words ~w(none off)

  @doc "Every account field spec, in display order."
  @spec all() :: [spec()]
  def all, do: @fields

  @doc "Field names settable in `phase` (`:create`, `:update`) or on the MCP surface (`:mcp`)."
  @spec names(:create | :update | :mcp) :: [String.t()]
  def names(:mcp), do: for(f <- @fields, f.mcp?, do: f.name)
  def names(phase), do: for(f <- @fields, phase in f.phases, do: f.name)

  @doc "The account's identity fields (`provider`, `slug`): create-only."
  @spec identity_names() :: [String.t()]
  def identity_names, do: @identity

  @doc "One field spec by name."
  @spec get(String.t()) :: spec() | nil
  def get(name), do: Enum.find(@fields, &(&1.name == name))

  @doc "The `quota_config` key specs: `%{name, type, doc}`."
  @spec quota_specs() :: [%{name: String.t(), type: atom(), doc: String.t()}]
  def quota_specs, do: @quota_specs

  @doc "Every `quota_config` key an operator may set or clear."
  @spec quota_keys() :: [String.t()]
  def quota_keys, do: @quota_keys

  # ---- attribute fields ------------------------------------------------------

  @doc """
  Validate and cast a set of account fields for `phase`. Keys may be strings or
  atoms; a key outside the phase's set (an identity field on `:update`, or
  anything unknown) is rejected by name rather than ignored.

  Returns the attribute changes keyed by atom. For `:update`, `quota_config` is
  the validated *patch* (a `nil` value clears that key); for `:create` it is the
  validated map with nil values dropped. `{:error, {:invalid_account, msg}}` or
  `{:error, {:invalid_quota_config, msg}}` otherwise.
  """
  @spec cast(map(), phase()) ::
          {:ok, map()}
          | {:error, {:invalid_account, String.t()}}
          | {:error, {:invalid_quota_config, String.t()}}
  def cast(attrs, phase) when is_map(attrs) and phase in [:create, :update] do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    allowed = names(phase)

    case Map.keys(attrs) -- allowed do
      [] ->
        attrs
        |> Enum.sort_by(fn {key, _} -> Enum.find_index(allowed, &(&1 == key)) end)
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case cast_field(get(key), value, phase) do
            {:ok, cast} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), cast)}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      unknown ->
        invalid_account("cannot set #{Enum.join(Enum.sort(unknown), ", ")}")
    end
  end

  defp cast_field(%{name: "provider"}, value, _phase) when is_atom(value) and not is_nil(value),
    do: {:ok, value}

  defp cast_field(%{name: "provider"}, value, _phase) do
    case Arbiter.Accounts.parse_provider(to_string(value)) do
      {:ok, provider} -> {:ok, provider}
      :error -> invalid_account("unknown provider #{inspect(value)}")
    end
  end

  defp cast_field(%{type: :text}, value, _phase) when is_nil(value) or is_binary(value) do
    text = if is_binary(value), do: String.trim(value)
    {:ok, if(text == "", do: nil, else: text)}
  end

  defp cast_field(%{type: :text, name: name}, _value, _phase),
    do: invalid_account("#{name} must be text")

  defp cast_field(%{name: "enabled"}, value, _phase) do
    case cast_boolean(value) do
      {:ok, bool} -> {:ok, bool}
      :error -> invalid_account("enabled must be true or false")
    end
  end

  defp cast_field(%{type: :count}, value, _phase), do: cast_count(value)

  defp cast_field(%{type: :quota_config}, value, phase) when is_map(value) do
    case phase do
      :create -> validate_quota_config(drop_nils(value), :set)
      :update -> validate_quota_config(value, :patch)
    end
  end

  defp cast_field(%{type: :quota_config}, _value, _phase),
    do: invalid_account("quota_config must be an object")

  defp drop_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)

  defp cast_boolean(value) when is_boolean(value), do: {:ok, value}
  defp cast_boolean("true"), do: {:ok, true}
  defp cast_boolean("false"), do: {:ok, false}
  defp cast_boolean(_), do: :error

  defp cast_count(nil), do: {:ok, nil}
  defp cast_count(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp cast_count(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> invalid_count()
        end
    end
  end

  defp cast_count(_), do: invalid_count()

  defp invalid_count,
    do: invalid_account("max_concurrent must be a non-negative integer or null")

  defp invalid_account(message), do: {:error, {:invalid_account, message}}

  # ---- quota_config --------------------------------------------------------

  @doc """
  Validate a `quota_config` map. `:set` (the default) is a create: every value
  must be valid. `:patch` is an update: a `nil` value is a clear for a known
  key and is kept as `nil` in the result for the caller to drop.

  Numbers are coerced to floats; `pace_exempt_priority` accepts `none` as its
  off switch, the same word the workspace side uses (D-A-22), which clears it.
  An unknown key is rejected outright, nil or not. The result is ready to
  `Map.merge/2` into the account's existing `quota_config`.
  """
  @spec validate_quota_config(map(), :set | :patch) ::
          {:ok, map()} | {:error, {:invalid_quota_config, String.t()}}
  def validate_quota_config(updates, mode \\ :set) when is_map(updates) do
    updates = Map.new(updates, fn {key, value} -> {to_string(key), value} end)
    updates = if mode == :set, do: drop_off_priority(updates), else: updates

    case Map.keys(updates) -- @quota_keys do
      [] ->
        updates
        |> Enum.sort()
        |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case validate_value(key, value, mode) do
            {:ok, validated} -> {:cont, {:ok, Map.put(acc, key, validated)}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      unknown ->
        invalid_quota("unknown quota_config key(s): #{Enum.join(Enum.sort(unknown), ", ")}")
    end
  end

  # On a create "off" is just the absent key.
  defp drop_off_priority(%{"pace_exempt_priority" => off} = updates) when off in @off_words,
    do: Map.delete(updates, "pace_exempt_priority")

  defp drop_off_priority(updates), do: updates

  defp validate_value("pace_exempt_priority", value, :patch) when value in @off_words,
    do: {:ok, nil}

  defp validate_value(_key, nil, :patch), do: {:ok, nil}

  defp validate_value("threshold_mode", mode, _) do
    if mode in Gate.threshold_modes() do
      {:ok, mode}
    else
      invalid_quota(
        "threshold_mode must be one of #{Enum.join(Gate.threshold_modes(), ", ")} (got #{inspect(mode)})"
      )
    end
  end

  defp validate_value("weekly_warning_policy", policy, _) do
    if policy in @policies do
      {:ok, policy}
    else
      invalid_quota(
        "weekly_warning_policy must be one of #{Enum.join(@policies, ", ")} (got #{inspect(policy)})"
      )
    end
  end

  defp validate_value("pace_exempt_priority", value, _) do
    case priority(value) do
      {:ok, p} ->
        {:ok, p}

      :error ->
        invalid_quota("pace_exempt_priority must be an integer in 0..4 (got #{inspect(value)})")
    end
  end

  defp validate_value("window_seconds", value, _), do: validate_window_seconds(value)

  defp validate_value(key, value, _) do
    case fraction(value) do
      {:ok, f} -> {:ok, f}
      :error -> invalid_quota("#{key} must be a number in 0..1 (got #{inspect(value)})")
    end
  end

  defp validate_window_seconds(table) when is_map(table) and map_size(table) > 0 do
    Enum.reduce_while(table, {:ok, %{}}, fn {label, seconds}, {:ok, acc} ->
      label = to_string(label)

      case seconds(seconds) do
        {:ok, n} when label != "" -> {:cont, {:ok, Map.put(acc, label, n)}}
        _ -> {:halt, invalid_window(label, seconds)}
      end
    end)
  end

  defp validate_window_seconds(other) do
    invalid_quota(
      "window_seconds must be a non-empty object of window label => positive seconds " <>
        "(got #{inspect(other)})"
    )
  end

  defp invalid_window(label, seconds) do
    invalid_quota(
      "window_seconds[#{inspect(label)}] must be a positive whole number of seconds " <>
        "with a non-empty label (got #{inspect(seconds)})"
    )
  end

  defp invalid_quota(message), do: {:error, {:invalid_quota_config, message}}

  defp fraction(n) when is_number(n) and n > 0 and n <= 1, do: {:ok, n * 1.0}

  defp fraction(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} when f > 0 and f <= 1 -> {:ok, f}
      _ -> :error
    end
  end

  defp fraction(_), do: :error

  defp priority(n) when is_integer(n) and n >= 0 and n <= 4, do: {:ok, n}

  defp priority(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> priority(n)
      _ -> :error
    end
  end

  defp priority(_), do: :error

  defp seconds(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp seconds(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp seconds(_), do: :error
end
