defmodule ArbiterWeb.ProvidersLive.AccountEditForm do
  @moduledoc """
  The per-account Edit form on `/providers` (bd-8vkqd3): `label`, `plan`,
  `enabled`, the concurrency cap and every settable `quota_config` key.

  `parse/1` validates the whole submission before anything is written, so a
  bad threshold can never leave the label saved and the policy not;
  `save/2` then goes through the same writers `PATCH /api/accounts/:ref`
  uses — `Accounts.update_account/2`, `Accounts.set_max_concurrent/2` and
  `Accounts.set_quota_config/2` — and re-implements none of their validation.

  A blank policy field clears its key (the account then falls back to the
  built-in default); it is never written as an empty string.

  The form carries no credential material: it is built from the account row
  alone, never from `ProviderCredential`. Credentials stay on the rotate /
  login flows.
  """
  use Phoenix.Component

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Forms

  @quota_keys ~w(threshold_mode weekly_threshold paced_floor weekly_paced_floor
                 pace_exempt_priority pace_exempt_threshold weekly_pace_exempt_threshold)

  @field_names %{
    "max_concurrent" => "concurrency cap",
    "label" => "label",
    "plan" => "plan",
    "enabled" => "status"
  }

  @doc "The form params an account opens with."
  @spec params(ProviderAccount.t()) :: map()
  def params(%ProviderAccount{} = account) do
    quota = account.quota_config || %{}

    %{
      "label" => account.label || "",
      "plan" => account.plan || "",
      "enabled" => to_string(account.enabled),
      "max_concurrent" =>
        if(account.max_concurrent, do: to_string(account.max_concurrent), else: "")
    }
    |> Map.merge(Map.new(@quota_keys, &{&1, display(Map.get(quota, &1))}))
  end

  defp display(nil), do: ""
  defp display(value), do: to_string(value)

  @doc """
  Validate a submission. `{:ok, edit}` is ready for `save/2`; `{:error,
  errors}` is a map of field name => message, each message naming its field.
  """
  @spec parse(map()) :: {:ok, map()} | {:error, %{optional(String.t()) => String.t()}}
  def parse(params) do
    attrs = Map.take(params, ["label", "plan", "enabled"])
    quota = Map.new(@quota_keys, &{&1, blank_to_nil(Map.get(params, &1))})

    errors =
      %{}
      |> check_attrs(attrs)
      |> check_cap(Map.get(params, "max_concurrent"))
      |> check_quota(quota)

    case errors do
      errors when map_size(errors) == 0 ->
        {:ok, %{attrs: attrs, max_concurrent: cap(params), quota: quota}}

      errors ->
        {:error, errors}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp check_attrs(errors, attrs) do
    case Accounts.validate_account_attrs(attrs) do
      {:ok, _changes} -> errors
      {:error, {:invalid_account, message}} -> Map.put(errors, "enabled", message)
    end
  end

  defp check_cap(errors, raw) do
    case parse_cap(raw) do
      {:ok, _cap} ->
        errors

      :error ->
        Map.put(
          errors,
          "max_concurrent",
          "The concurrency cap must be a whole number, 0 or more."
        )
    end
  end

  defp cap(params) do
    {:ok, cap} = parse_cap(Map.get(params, "max_concurrent"))
    cap
  end

  defp parse_cap(raw) do
    case blank_to_nil(raw) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :error
        end
    end
  end

  # One validation pass per field so each error lands on its own input. The
  # message is `Gate`'s own, which already names the key and the valid range.
  defp check_quota(errors, quota) do
    Enum.reduce(quota, errors, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc ->
        case Gate.validate_quota_config(%{key => value}) do
          {:ok, _} -> acc
          {:error, {:invalid_quota_config, message}} -> Map.put(acc, key, message)
        end
    end)
  end

  @doc """
  Write a parsed edit. Returns `{:ok, account}` or `{:error, message}`.
  """
  @spec save(String.t(), map()) :: {:ok, ProviderAccount.t()} | {:error, String.t()}
  def save(account_id, %{attrs: attrs, max_concurrent: cap, quota: quota}) do
    result =
      with {:ok, _} <- Accounts.update_account(account_id, attrs),
           {:ok, _} <- Accounts.set_max_concurrent(account_id, cap) do
        Accounts.set_quota_config(account_id, quota)
      end

    case result do
      {:ok, account} -> {:ok, account}
      {:error, error} -> {:error, describe(error)}
    end
  end

  defp describe({:invalid_account, message}), do: message
  defp describe({:invalid_quota_config, message}), do: message
  defp describe(:not_found), do: "This account no longer exists. Reload the page."

  defp describe(%Ash.Error.Invalid{errors: errors}),
    do: Enum.map_join(errors, "; ", &Exception.message/1)

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(other), do: "Could not save: #{inspect(other)}"

  @doc "The fields an error map names, in form order, for the summary line."
  @spec error_fields(map()) :: [String.t()]
  def error_fields(errors) do
    order = ~w(label plan enabled max_concurrent) ++ @quota_keys
    Enum.filter(order, &Map.has_key?(errors, &1))
  end

  @doc """
  The effective ceiling per attached workspace that sets its own quota
  policy: the gate's `min(account, workspace)`, with the binding side named.
  Computed from the *saved* account.
  """
  @spec effective(ProviderAccount.t(), [map()]) :: [map()]
  def effective(account, links) do
    for link <- links, quota = link[:workspace_quota], quota != %{} do
      policy = {account, %Workspace{config: %{"quota" => quota}}}

      %{
        workspace_id: link.workspace_id,
        workspace_name: link.workspace_name,
        short: effective_threshold(policy, :throttle_threshold),
        long: effective_threshold(policy, :weekly_threshold),
        exempt: exempt(policy, quota)
      }
    end
  end

  defp effective_threshold(policy, key) do
    %{
      value: policy |> Gate.effective_threshold(key) |> Float.round(2),
      side: Gate.binding_side(policy, key)
    }
  end

  defp exempt(policy, %{"pace_exempt_priority" => _}), do: Gate.pace_exempt_priority(policy)
  defp exempt(_policy, _quota), do: :unset

  defp side_text(:account), do: "account"
  defp side_text(:workspace), do: "workspace"
  defp side_text(:default), do: "built-in default"

  defp exempt_text(:unset), do: nil
  defp exempt_text(nil), do: "pace exemption off"
  defp exempt_text(0), do: "pace exemption: P0 only"
  defp exempt_text(n), do: "pace exemption: P0 to P#{n}"

  @mode_options [
    {"Default (flat)", ""},
    {"Flat — a fixed ceiling", "flat"},
    {"Paced — tracks the window", "paced"}
  ]
  @status_options [{"Enabled", "true"}, {"Parked — kept, but never routed to", "false"}]
  @priority_options [
    {"Off — nothing is exempt", ""},
    {"P0 only", "0"},
    {"P0 to P1", "1"},
    {"P0 to P2", "2"},
    {"P0 to P3", "3"},
    {"P0 to P4", "4"}
  ]

  attr :row, :map, required: true, doc: "the `Overview` row of the account being edited"
  attr :form, :any, required: true
  attr :errors, :map, default: %{}
  attr :save_error, :string, default: nil

  def edit_form(assigns) do
    assigns =
      assigns
      |> assign(:account, assigns.row.account)
      |> assign(:effective, effective(assigns.row.account, assigns.row.workspaces))
      |> assign(:fields, error_fields(assigns.errors))

    ~H"""
    <.form
      for={@form}
      id={"edit-form-#{@account.id}"}
      phx-submit="save_edit"
      class="px-[18px] py-4 border-b border-[var(--border-default)] bg-[var(--arb-panel-alt)] flex flex-col gap-4"
    >
      <input type="hidden" name="account_id" value={@account.id} />

      <fieldset class="m-0 p-0 border-0 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 items-end gap-3">
        <legend class="mb-2 text-[11px] uppercase tracking-wide text-[var(--text-label)]">
          Account
        </legend>
        <.field
          form={@form}
          id={@account.id}
          key="label"
          label="Label"
          errors={@errors}
          placeholder="Work Max plan"
        />
        <.field
          form={@form}
          id={@account.id}
          key="plan"
          label="Plan"
          errors={@errors}
          placeholder="max_20x"
        />
        <.select_field
          form={@form}
          id={@account.id}
          key="enabled"
          label="Status"
          options={status_options()}
          errors={@errors}
        />
        <.field
          form={@form}
          id={@account.id}
          key="max_concurrent"
          label="Concurrency cap"
          hint="blank = no cap"
          type="number"
          min="0"
          errors={@errors}
          placeholder="no cap"
        />
      </fieldset>

      <fieldset class="m-0 p-0 border-0 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 items-end gap-3">
        <legend class="mb-2 text-[11px] uppercase tracking-wide text-[var(--text-label)]">
          Quota ceilings
        </legend>
        <p
          id={"edit-form-#{@account.id}-floor-help"}
          class="m-0 sm:col-span-2 lg:col-span-4 max-w-3xl text-[12px] text-[var(--arb-text-muted)]"
        >
          These values are a floor. Each attached workspace can only tighten them: the gate uses the lower of the account's and the workspace's value, so a workspace never loosens what is set here. Leave a field blank to unset it and use the built-in default.
        </p>
        <.select_field
          form={@form}
          id={@account.id}
          key="threshold_mode"
          label="Threshold mode"
          hint="threshold_mode"
          options={mode_options()}
          errors={@errors}
        />
        <.field
          form={@form}
          id={@account.id}
          key="weekly_threshold"
          label="7-day ceiling"
          hint="weekly_threshold"
          errors={@errors}
          placeholder="0.90"
          inputmode="decimal"
        />
        <.field
          form={@form}
          id={@account.id}
          key="paced_floor"
          label="5-hour paced floor"
          hint="paced_floor"
          errors={@errors}
          placeholder="0.35"
          inputmode="decimal"
        />
        <.field
          form={@form}
          id={@account.id}
          key="weekly_paced_floor"
          label="7-day paced floor"
          hint="weekly_paced_floor"
          errors={@errors}
          placeholder="0.20"
          inputmode="decimal"
        />
        <p class="m-0 sm:col-span-2 lg:col-span-4 max-w-3xl text-[12px] text-[var(--arb-text-muted)]">
          Ceilings are fractions above 0 and up to 1 (0.9 = 90% of the window). The 7-day ceiling applies in flat mode; the paced floors apply in paced mode, where the ceiling rises with the window's elapsed time.
        </p>
        <p
          :for={e <- @effective}
          id={"edit-form-#{@account.id}-effective-#{e.workspace_id}"}
          class="m-0 sm:col-span-2 lg:col-span-4 text-[12px] text-[var(--arb-text-body)] font-[family-name:var(--font-mono)]"
        >
          With {e.workspace_name}: 5-hour {e.short.value} ({side_text(e.short.side)}) · 7-day {e.long.value} ({side_text(
            e.long.side
          )}){if text = exempt_text(e.exempt), do: " · " <> text}
          <span class="text-[var(--arb-text-muted)]">
            — saved values; the lower of the two applies
          </span>
        </p>
      </fieldset>

      <fieldset class="m-0 p-0 border-0 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 items-end gap-3">
        <legend class="mb-2 text-[11px] uppercase tracking-wide text-[var(--text-label)]">
          Pace exemption
        </legend>
        <p class="m-0 sm:col-span-2 lg:col-span-4 max-w-3xl text-[12px] text-[var(--arb-text-muted)]">
          Lets urgent tickets run past the paced line, up to the caps below (never past the flat ceiling). Off until you pick a priority. A workspace can narrow this, never grant it.
        </p>
        <.select_field
          form={@form}
          id={@account.id}
          key="pace_exempt_priority"
          label="Exempt priorities"
          hint="pace_exempt_priority"
          options={priority_options()}
          errors={@errors}
        />
        <.field
          form={@form}
          id={@account.id}
          key="pace_exempt_threshold"
          label="5-hour exempt cap"
          hint="pace_exempt_threshold"
          errors={@errors}
          placeholder="flat ceiling"
          inputmode="decimal"
        />
        <.field
          form={@form}
          id={@account.id}
          key="weekly_pace_exempt_threshold"
          label="7-day exempt cap"
          hint="weekly_pace_exempt_threshold"
          errors={@errors}
          placeholder="flat ceiling"
          inputmode="decimal"
        />
      </fieldset>

      <p
        :if={@account.provider == :grok}
        id={"edit-form-#{@account.id}-grok-note"}
        class="m-0 max-w-3xl text-[12px] text-[var(--arb-text-muted)]"
      >
        Whether Grok receives any work is set per workspace, with "Route D1 tickets to Grok" in its Providers settings. Nothing here changes that.
      </p>

      <p
        :if={@fields != [] or @save_error}
        id={"edit-form-#{@account.id}-error"}
        role="alert"
        class="m-0 text-[12px] text-[var(--arb-fail-text)]"
      >
        <%= if @fields != [] do %>
          Nothing was saved. Fix {Enum.map_join(@fields, ", ", &field_name/1)} and save again.
        <% else %>
          {@save_error}
        <% end %>
      </p>

      <div class="flex gap-2">
        <Core.button id={"edit-form-#{@account.id}-save"} type="submit" variant="primary" size="sm">
          Save changes
        </Core.button>
        <Core.button
          id={"edit-form-#{@account.id}-cancel"}
          type="button"
          variant="ghost"
          size="sm"
          phx-click="cancel_edit"
        >
          Cancel
        </Core.button>
      </div>
    </.form>
    """
  end

  defp field_name(key), do: Map.get(@field_names, key, key)
  defp status_options, do: @status_options
  defp mode_options, do: @mode_options
  defp priority_options, do: @priority_options

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :errors, :map, default: %{}
  attr :rest, :global, include: ~w(type min placeholder inputmode)

  defp field(assigns) do
    ~H"""
    <Forms.input
      id={"edit-#{@id}-#{@key}"}
      name={"edit[#{@key}]"}
      value={@form.params[@key]}
      label={@label}
      hint={@hint}
      error={@errors[@key]}
      aria-invalid={if @errors[@key], do: "true"}
      {@rest}
    />
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :options, :list, required: true
  attr :errors, :map, default: %{}

  defp select_field(assigns) do
    ~H"""
    <Forms.select
      id={"edit-#{@id}-#{@key}"}
      name={"edit[#{@key}]"}
      value={@form.params[@key]}
      label={if @hint, do: "#{@label} — #{@hint}", else: @label}
      options={@options}
      error={@errors[@key]}
    />
    """
  end
end
