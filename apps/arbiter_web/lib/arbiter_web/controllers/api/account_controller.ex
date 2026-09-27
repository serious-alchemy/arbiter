defmodule ArbiterWeb.Api.AccountController do
  @moduledoc """
  REST endpoints for `Arbiter.Accounts.ProviderAccount` (P11,
  `docs/provider-account-design.md` §2.5). Backs the `arb account` CLI.

  Routes:

    * `GET    /api/accounts`            — :index (optional `?provider=`, `?include_merged=true`,
      `?include_deleted=true`)
    * `POST   /api/accounts`            — :create
    * `GET    /api/accounts/:ref`       — :show   (`:ref` — uuid, `provider:slug`, or bare slug)
    * `PATCH  /api/accounts/:ref`       — :update (`max_concurrent`, nullable;
      `quota_config`, a partial merge — `threshold_mode`, `weekly_threshold`,
      `paced_floor`, `weekly_paced_floor`)
    * `POST   /api/accounts/:ref/attach`  — :attach (`workspace_id`, `provider`, optional `share`)
    * `POST   /api/accounts/:ref/rotate`  — :rotate (`kind`, `env_var`, `secret`, optional `scopes`)
    * `POST   /api/accounts/:ref/merge`   — :merge  (`into` — the surviving account ref)
    * `DELETE /api/accounts/:ref`         — :delete (optional `?detach=true`, `?hard=true`)

  `:ref` resolution is `Arbiter.Accounts.get_account/1` — a bare slug that
  matches more than one provider's account is rejected as ambiguous.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Accounts

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

  defp truthy?(v), do: v in ["true", "1", true]

  def show(conn, %{"ref" => ref}) do
    with {:ok, account} <- ref |> Accounts.get_account() |> friendly() do
      render(conn, :show, account: account)
    end
  end

  def create(conn, params) do
    attrs =
      Map.take(params, [
        "provider",
        "slug",
        "label",
        "plan",
        "provider_account_ref",
        "provider_org_ref",
        "max_concurrent",
        "quota_config",
        "enabled"
      ])

    with {:ok, account} <- attrs |> Accounts.create_account() |> friendly() do
      conn
      |> put_status(:created)
      |> render(:show, account: account)
    end
  end

  @doc """
  The account concurrency ceiling (P8, `docs/provider-account-design.md`
  §4.2) and/or the account's gate policy (bd-c7ll4t). `max_concurrent` is
  nullable and an explicit `null` clears it: the ceiling is opt-in (§4.4), so
  "no ceiling" has to be reachable, and giving the key an absent value is a
  malformed request rather than a clear. `quota_config` is a **partial**
  merge — `threshold_mode`, `weekly_threshold`, `paced_floor`,
  `weekly_paced_floor` — validated against `Arbiter.Quota.Gate
  .threshold_modes/0` and 0..1 floats; keys not mentioned (e.g.
  `throttle_threshold`) are left untouched. At least one of the two must be
  given.

  Before `quota_config` landed here, an existing account's gate policy could
  only be edited with `bin/arbiter eval` (bd-5ps98m) — `PATCH` accepted only
  `max_concurrent`, and `quota_config` was settable solely at `create`.

  `provider`/`slug` are still never accepted here — they are the account's
  identity (§3.1) and changing either is a new account, not an edit.
  """
  def update(conn, %{"ref" => ref} = params) do
    with {:ok, max_concurrent} <- fetch_max_concurrent(params),
         {:ok, quota_config} <- fetch_quota_config(params),
         :ok <- require_an_update(max_concurrent, quota_config),
         {:ok, account} <- apply_updates(ref, max_concurrent, quota_config) do
      render(conn, :show, account: account)
    end
  end

  defp fetch_max_concurrent(params) do
    case Map.fetch(params, "max_concurrent") do
      :error -> {:ok, :absent}
      {:ok, value} -> with {:ok, v} <- cast_max_concurrent(value), do: {:ok, {:set, v}}
    end
  end

  defp cast_max_concurrent(nil), do: {:ok, nil}
  defp cast_max_concurrent(""), do: {:ok, nil}
  defp cast_max_concurrent(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp cast_max_concurrent(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> invalid_max_concurrent()
    end
  end

  defp cast_max_concurrent(_), do: invalid_max_concurrent()

  defp invalid_max_concurrent,
    do: {:error, {:invalid_request, "max_concurrent must be a non-negative integer or null"}}

  # Validated here, before `apply_updates/3` writes anything (bd-c7ll4t) — a
  # `PATCH` with a bad `quota_config` alongside a good `max_concurrent` must
  # not persist the `max_concurrent` half and then 422 on the other; the two
  # updates read as one request.
  defp fetch_quota_config(params) do
    case Map.fetch(params, "quota_config") do
      :error ->
        {:ok, :absent}

      {:ok, %{} = updates} ->
        case Arbiter.Quota.Gate.validate_quota_config(updates) |> friendly() do
          {:ok, validated} -> {:ok, {:set, validated}}
          {:error, _} = err -> err
        end

      {:ok, _} ->
        {:error, {:invalid_request, "quota_config must be an object"}}
    end
  end

  defp require_an_update(:absent, :absent),
    do: {:error, {:invalid_request, "missing required parameter: max_concurrent or quota_config"}}

  defp require_an_update(_max_concurrent, _quota_config), do: :ok

  defp apply_updates(ref, max_concurrent, quota_config) do
    with {:ok, account} <- ref |> apply_max_concurrent(max_concurrent) |> friendly() do
      account |> apply_quota_config(quota_config) |> friendly()
    end
  end

  defp apply_max_concurrent(ref, :absent), do: Accounts.get_account(ref)
  defp apply_max_concurrent(ref, {:set, value}), do: Accounts.set_max_concurrent(ref, value)

  defp apply_quota_config(account, :absent), do: {:ok, account}

  defp apply_quota_config(%{id: id}, {:set, updates}),
    do: Accounts.set_quota_config(id, updates)

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

  defp friendly({:error, {:invalid_quota_config, message}}),
    do: {:error, {:invalid_request, message}}

  defp friendly(other), do: other

  defp survivor_ref(survivor_id) do
    case Ash.get(Accounts.ProviderAccount, survivor_id) do
      {:ok, %{provider: provider, slug: slug}} -> "#{provider}:#{slug}"
      {:error, _} -> survivor_id
    end
  end
end
