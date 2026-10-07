defmodule ArbiterWeb.Api.AccountController do
  @moduledoc """
  REST endpoints for `Arbiter.Accounts.ProviderAccount` (P11,
  `docs/provider-account-design.md` §2.5). Backs the `arb account` CLI.

  Routes:

    * `GET    /api/accounts`            — :index (optional `?provider=`, `?include_merged=true`,
      `?include_deleted=true`)
    * `POST   /api/accounts`            — :create
    * `GET    /api/accounts/:ref`       — :show   (`:ref` — uuid, `provider:slug`, or bare slug)
    * `PATCH  /api/accounts/:ref`       — :update (`label`, `plan`, `enabled`;
      `max_concurrent`, nullable; `quota_config`, a partial merge of every key in
      `Arbiter.Accounts.Fields.quota_keys/0`; a `null` value clears that key).
      One write: a failure leaves the account untouched.
    * `POST   /api/accounts/:ref/attach`  — :attach (`workspace_id`, `provider`, optional `share`;
      not for a `grok` account)
    * `DELETE /api/accounts/:ref/attach/:workspace_id` — :detach (one workspace's link only)
    * `POST   /api/accounts/:ref/rotate`  — :rotate (`kind`, `env_var`, `secret`, optional `scopes`)
    * `POST   /api/accounts/:ref/merge`   — :merge  (`into` — the surviving account ref)
    * `DELETE /api/accounts/:ref`         — :delete (optional `?detach=true`, `?hard=true`)

  The settable fields, their types and validation live in the one registry,
  `Arbiter.Accounts.Fields` (bd-1kr3qf); `create` and `update` take their
  whitelist from it and share its validator, so a bad `quota_config` is a 422
  `validation_error` on both.

  `:ref` resolution is `Arbiter.Accounts.get_account/1` — a bare slug that
  matches more than one provider's account is rejected as ambiguous.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Fields
  alias Arbiter.Params

  action_fallback ArbiterWeb.Api.FallbackController

  def index(conn, params) do
    with {:ok, opts} <- provider_filter(params) do
      opts =
        opts
        |> Keyword.put(:include_merged, truthy?(Map.get(params, "include_merged")))
        |> Keyword.put(:include_deleted, truthy?(Map.get(params, "include_deleted")))

      render(conn, :index, accounts: Accounts.list_accounts(opts))
    end
  end

  defp provider_filter(params) do
    case Map.get(params, "provider") do
      nil ->
        {:ok, []}

      provider ->
        case Accounts.parse_provider(provider) do
          {:ok, p} -> {:ok, [provider: p]}
          :error -> {:error, {:invalid_request, "unknown provider"}}
        end
    end
  end

  defp truthy?(v), do: Params.boolean(v) == {:ok, true}

  def show(conn, %{"ref" => ref}) do
    with {:ok, account} <- ref |> Accounts.get_account() |> friendly() do
      render(conn, :show, account: account)
    end
  end

  def create(conn, params) do
    attrs = Map.take(params, Fields.names(:create))

    with {:ok, account} <- attrs |> Accounts.create_account() |> friendly() do
      conn
      |> put_status(:created)
      |> render(:show, account: account)
    end
  end

  @doc """
  Edit an account — `label`, `plan`, `enabled`, `max_concurrent` (nullable; an
  explicit `null` clears the ceiling, which is opt-in per §4.4) and/or a
  **partial** `quota_config` merge (bd-c7ll4t): any key in
  `Arbiter.Accounts.Fields.quota_keys/0`, with a `null` value clearing that
  key; keys not mentioned are left untouched. At least one field must be given.

  The whole request is validated by `Arbiter.Accounts.Fields` and written by
  `Arbiter.Accounts.edit_account/2` as a single update (bd-1kr3qf, D-A-20), so
  a bad value anywhere rejects the request and a failure writes nothing.
  `provider` / `slug` are the account's identity (§3.1) and are rejected by
  name: changing either is a new account, not an edit.
  """
  def update(conn, %{"ref" => ref} = params) do
    attrs = Map.take(params, Fields.names(:update) ++ Fields.identity_names())

    if attrs == %{} do
      {:error,
       {:invalid_request,
        "missing required parameter: one of #{Enum.join(Fields.names(:update), ", ")}"}}
    else
      with {:ok, account} <- ref |> Accounts.edit_account(attrs) |> friendly() do
        render(conn, :show, account: account)
      end
    end
  end

  def attach(conn, %{"ref" => ref} = params) do
    with {:ok, workspace_id} <- require_param(params, "workspace_id"),
         {:ok, provider} <- require_param(params, "provider"),
         {:ok, link} <-
           Accounts.attach_workspace(workspace_id, provider, ref, share_opts(params))
           |> friendly() do
      conn
      |> put_status(:created)
      |> render(:attach, link: link)
    end
  end

  # `share` is only forwarded when the caller actually sent it — an absent
  # key must leave an existing share untouched (Accounts.attach_workspace/4),
  # not clobber it back to nil.
  defp share_opts(params) do
    case Map.get(params, "share") do
      nil -> []
      share -> [share: share]
    end
  end

  @doc """
  Detach one workspace from an account (the inverse of `attach/2`): removes only
  that `(workspace, provider)` link, and only while it still points at this
  account.
  """
  def detach(conn, %{"ref" => ref, "workspace_id" => workspace_id}) do
    with {:ok, link} <- workspace_id |> Accounts.detach_workspace(ref) |> friendly() do
      render(conn, :attach, link: link)
    end
  end

  def rotate(conn, %{"ref" => ref} = params) do
    attrs = Map.take(params, ["kind", "env_var", "secret", "scopes"])

    with {:ok, credential} <- ref |> Accounts.rotate_credential(attrs) |> friendly() do
      conn
      |> put_status(:created)
      |> render(:credential, credential: credential)
    end
  end

  def merge(conn, %{"ref" => ref} = params) do
    with {:ok, into} <- require_param(params, "into"),
         {:ok, account} <- ref |> Accounts.merge_accounts(into) |> friendly() do
      render(conn, :show, account: account)
    end
  end

  @doc """
  Delete an account (bd-agb7ai). Soft-delete by default; `?hard=true` for a
  hard delete (only permitted for an account with no `usage_events` row and
  no `provider_credentials` row, ever); `?detach=true` to remove the
  account's `workspace_provider_accounts` links as part of the delete — a
  link required by a workspace's implementer/reviewer settings is never
  removed this way, `:detach` included. See `Accounts.delete_account/2`.
  """
  def delete(conn, %{"ref" => ref} = params) do
    opts = [detach: truthy?(Map.get(params, "detach")), hard: truthy?(Map.get(params, "hard"))]

    with {:ok, account} <- ref |> Accounts.delete_account(opts) |> friendly() do
      render(conn, :show, account: account)
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, {:invalid_request, "missing required parameter: #{key}"}}
      "" -> {:error, {:invalid_request, "missing required parameter: #{key}"}}
      value -> {:ok, value}
    end
  end

  # Normalises the plain-atom/tuple error shapes `Arbiter.Accounts` returns
  # (never seen by `Ash.Error`) into the `{:invalid_request, message}` shape
  # `ArbiterWeb.Api.FallbackController` already renders as 400. `:not_found`
  # and `%Ash.Error.Invalid{}` pass through unchanged — the fallback handles
  # both directly.
  defp friendly({:ok, _} = ok), do: ok
  defp friendly({:error, :not_found} = err), do: err
  defp friendly({:error, %Ash.Error.Invalid{}} = err), do: err

  defp friendly({:error, :ambiguous}),
    do: {:error, {:invalid_request, "ambiguous account reference — use provider:slug"}}

  defp friendly({:error, :same_account}),
    do: {:error, {:invalid_request, "cannot merge an account into itself"}}

  defp friendly({:error, :provider_mismatch}),
    do: {:error, {:invalid_request, "cannot merge accounts across providers"}}

  defp friendly({:error, :already_merged}),
    do: {:error, {:invalid_request, "the account being merged has already been merged away"}}

  defp friendly({:error, :into_already_merged}),
    do:
      {:error,
       {:invalid_request, "cannot merge into an account that has already been merged away"}}

  defp friendly({:error, {:invalid_kind, kind}}),
    do: {:error, {:invalid_request, "unknown credential kind #{inspect(kind)}"}}

  defp friendly({:error, {:invalid_credentials_path, reason}}),
    do:
      {:error,
       {:invalid_request,
        "no readable Claude grant at that path (#{reason}); log the config dir in first " <>
          "with `CLAUDE_CONFIG_DIR=<dir> claude auth login`"}}

  defp friendly({:error, {:provider_mismatch, provider}}),
    do: {:error, {:invalid_request, "account belongs to provider #{provider}, not the one given"}}

  defp friendly({:error, {:invalid_provider, provider}}),
    do: {:error, {:invalid_request, "unknown provider #{inspect(provider)}"}}

  defp friendly({:error, {:merged_away, survivor_id}}),
    do: {:error, {:invalid_request, "account has been merged into #{survivor_ref(survivor_id)}"}}

  defp friendly({:error, :already_deleted}),
    do: {:error, {:invalid_request, "account has already been deleted"}}

  defp friendly({:error, {:pinned_by_task, task_id}}),
    do:
      {:error,
       {:invalid_request, "account is pinned by running task #{task_id}'s provider routing"}}

  defp friendly({:error, {:required_by_workspace, workspace_id, roles}}),
    do:
      {:error,
       {:invalid_request,
        "account is required by workspace #{workspace_id}'s #{Enum.join(roles, "/")} setting"}}

  defp friendly({:error, {:attached, workspace_ids}}),
    do:
      {:error,
       {:invalid_request,
        "account is attached to workspace(s) #{Enum.join(workspace_ids, ", ")} — " <>
          "detach first, or pass ?detach=true"}}

  defp friendly({:error, {:missing_credential_risk, workspace_id}}),
    do:
      {:error,
       {:invalid_request,
        "workspace #{workspace_id} still carries this provider's credential in its worker " <>
          "env — detaching would leave it with no credential source"}}

  defp friendly({:error, :hard_delete_blocked}),
    do:
      {:error,
       {:invalid_request,
        "hard delete requires an account with no usage rows and no credentials, ever"}}

  defp friendly({:error, {:missing, key}}),
    do: {:error, {:invalid_request, "missing required field: #{key}"}}

  # A well-formed request whose values are unacceptable: 422 `validation_error`,
  # the same on create and PATCH.
  defp friendly({:error, {:invalid_quota_config, message}}),
    do: {:error, {:invalid, message}}

  defp friendly({:error, {:invalid_account, message}}),
    do: {:error, {:invalid, message}}

  defp friendly({:error, :grok_routed_by_opt_in}),
    do:
      {:error,
       {:invalid_request,
        "Grok is routed by the workspace's \"Route D1 tickets to Grok\" setting, not attached to an account"}}

  defp friendly({:error, :not_attached}),
    do: {:error, {:invalid_request, "that workspace is not attached to this account"}}

  defp friendly(other), do: other

  defp survivor_ref(survivor_id) do
    case Ash.get(Accounts.ProviderAccount, survivor_id) do
      {:ok, %{provider: provider, slug: slug}} -> "#{provider}:#{slug}"
      {:error, _} -> survivor_id
    end
  end
end
