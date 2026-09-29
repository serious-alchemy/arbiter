defmodule Arbiter.Accounts do
  @moduledoc """
  Ash domain for provider accounts (`docs/provider-account-design.md`).

  Phases P1 (bd-4qa1iw), P2 (bd-77j2if) and P3 (bd-aiodva). P1 created the
  three tables; P2 added `Arbiter.Accounts.Migrate` — the plan-driven
  extraction that populates them out of each workspace's encrypted
  `worker_env` — and `Arbiter.Accounts.ProviderAccountMigrationBackup`, its
  undo record.

  P3 is §7.5's "Release N+1 — read flip": `Arbiter.Accounts.Credentials`
  reads these tables, and `Arbiter.Agents.Claude.ConfigDir` /
  `Arbiter.Worker.WorkerEnv` source provider credentials from it. P13
  (bd-9gqj8e) is the flip release: the `:provider_accounts_enabled` flag and
  the legacy `worker_env` / server-env credential chain it guarded are gone,
  so these tables are the only source of a spawn's provider credential. A
  workspace that still carries a provider credential in its `worker_env` but
  has no account to supply it raises
  `Arbiter.Accounts.MissingCredentialError` at spawn rather than dispatching
  a worker with no credential; `Arbiter.Accounts.Enablement` names those
  workspaces at boot and in `arb server doctor`.

  `Arbiter.Accounts.Census` (P0) is a plain module, not a resource in this
  domain; it inspects `worker_env` read-only and emits the candidate plan
  `Arbiter.Accounts.Migrate` consumes.
  """

  use Ash.Domain

  require Ash.Query

  resources do
    resource Arbiter.Accounts.ProviderAccount
    resource Arbiter.Accounts.ProviderCredential
    resource Arbiter.Accounts.ProviderAccountMigrationBackup
    resource Arbiter.Accounts.WorkspaceProviderAccount
  end

  alias Arbiter.Accounts.{
    Census,
    Merge,
    ProviderAccount,
    ProviderCredential,
    WorkspaceProviderAccount
  }

  alias Arbiter.Quota.GrantFile
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event

  @doc """
  List accounts, ordered by provider then slug. Excludes merged-away rows
  (`merged_into_id` set) unless `:include_merged` is true, and excludes
  soft-deleted rows (`deleted_at` set, bd-agb7ai) unless `:include_deleted` is
  true — P11's `arb account list`.
  """
  @spec list_accounts(keyword()) :: [ProviderAccount.t()]
  def list_accounts(opts \\ []) do
    query = ProviderAccount |> Ash.Query.sort(provider: :asc, slug: :asc)

    query =
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> Ash.Query.filter(query, provider == ^provider)
      end

    query =
      if Keyword.get(opts, :include_merged, false) do
        query
      else
        Ash.Query.filter(query, is_nil(merged_into_id))
      end

    query =
      if Keyword.get(opts, :include_deleted, false) do
        query
      else
        Ash.Query.filter(query, is_nil(deleted_at))
      end

    Ash.read!(query)
  end

  @doc """
  Resolve one account by, in order: a UUID id, a `"provider:slug"` ref, or a
  bare `slug` — which must be unambiguous (a slug is only unique *within* a
  provider, per `ProviderAccount`'s identity). Returns `{:error, :not_found}`
  or `{:error, :ambiguous}` (bare slug matching more than one provider).
  """
  @spec get_account(String.t()) :: {:ok, ProviderAccount.t()} | {:error, :not_found | :ambiguous}
  def get_account(ref) when is_binary(ref) do
    cond do
      uuid?(ref) -> fetch_by_id(ref)
      String.contains?(ref, ":") -> fetch_by_provider_slug(ref)
      true -> fetch_by_bare_slug(ref)
    end
  end

  defp fetch_by_id(id) do
    case Ash.get(ProviderAccount, id) do
      {:ok, account} -> {:ok, account}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp fetch_by_provider_slug(ref) do
    with [provider_str, slug] <- String.split(ref, ":", parts: 2),
         {:ok, provider} <- parse_provider(provider_str) do
      ProviderAccount
      |> Ash.Query.filter(provider == ^provider and slug == ^slug)
      |> Ash.read_one()
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, account} -> {:ok, account}
        {:error, _} -> {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch_by_bare_slug(slug) do
    ProviderAccount
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read!()
    |> case do
      [] -> {:error, :not_found}
      [account] -> {:ok, account}
      [_ | _] -> {:error, :ambiguous}
    end
  end

  @doc """
  Parse a provider string against the known set of provider atoms
  (`claude`, `codex`, `antigravity`). Returns `:error` for
  anything else, whether or not that string happens to already be an atom
  elsewhere in the VM.
  """
  @spec parse_provider(String.t()) :: {:ok, atom()} | :error
  def parse_provider(str) do
    case str do
      s when s in ~w(claude codex antigravity) -> {:ok, String.to_existing_atom(s)}
      _ -> :error
    end
  end

  # Canonical 36-character form only. `Ecto.UUID.cast/1` also accepts a raw
  # 16-*byte* binary, which silently claimed every ref that happened to be 16
  # characters long ("claude:ceil-refs") for the id branch, so it 404'd
  # instead of resolving as `provider:slug` / a bare slug.
  defp uuid?(str), do: byte_size(str) == 36 and match?({:ok, _}, Ecto.UUID.cast(str))

  @doc """
  Create a new `ProviderAccount` — `arb account create`. Operator-asserted
  identity (§2.4): no credential is required at creation time.
  """
  @spec create_account(map()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  def create_account(attrs) when is_map(attrs), do: Ash.create(ProviderAccount, attrs)

  @doc """
  Set (or clear, with `nil`) the account concurrency ceiling (P8,
  `docs/provider-account-design.md` §4.2): at most `max_concurrent` workers
  may be live on this account across *every* workspace metered under it.

  `nil` is the migrated default (§4.4) and means no account ceiling —
  today's behaviour, bit-for-bit. Nothing is enforced until an operator picks
  a number.
  """
  @spec set_max_concurrent(String.t(), non_neg_integer() | nil) ::
          {:ok, ProviderAccount.t()} | {:error, term()}
  def set_max_concurrent(account_ref, max_concurrent)
      when is_nil(max_concurrent) or (is_integer(max_concurrent) and max_concurrent >= 0) do
    with {:ok, account} <- get_account(account_ref) do
      Ash.update(account, %{max_concurrent: max_concurrent})
    end
  end

  @doc """
  Merge quota-policy fields into an account's `quota_config` — `arb account
  set --threshold-mode ... --weekly-threshold ...` / `PATCH
  /api/accounts/:ref` (bd-c7ll4t). Before this, `quota_config` was settable
  only at `create`; an existing account (`claude:default` in bd-5ps98m) could
  only be corrected with `bin/arbiter eval` because `ProviderAccount`'s
  `:update` action already accepted the attribute, just nothing above the
  Ash layer wrote to it.

  `updates` is validated by `Arbiter.Quota.Gate.validate_quota_config/1`
  first — an invalid `threshold_mode` or an out-of-range float never reaches
  the resource. Only the given keys are touched: `Map.merge/2` onto the
  account's current `quota_config` leaves sibling keys (`throttle_threshold`,
  `weekly_warning_policy`, ...) exactly as they were.
  """
  @spec set_quota_config(String.t(), map()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  def set_quota_config(account_ref, updates) when is_map(updates) do
    with {:ok, validated} <- Arbiter.Quota.Gate.validate_quota_config(updates),
         {:ok, account} <- get_account(account_ref) do
      Ash.update(account, %{quota_config: Map.merge(account.quota_config || %{}, validated)})
    end
  end

  @doc """
  Attach a workspace to an account for a provider — `arb account attach
  <workspace> <provider> <slug> [--share N]`. Writes or updates the
  `(workspace_id, provider)` `WorkspaceProviderAccount` row (`ProviderAccount`
  ref resolved via `get_account/1`).

  `:share` is only touched when the caller explicitly passes it — a bare
  re-attach (no `--share`) leaves an existing share in place instead of
  clobbering it back to `nil`.
  """
  @spec attach_workspace(String.t(), atom() | String.t(), String.t(), keyword()) ::
          {:ok, WorkspaceProviderAccount.t()} | {:error, term()}
  def attach_workspace(workspace_id, provider, account_ref, opts \\ []) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, _workspace} <- get_workspace(workspace_id),
         {:ok, account} <- get_account(account_ref),
         :ok <- ensure_not_merged_away(account),
         :ok <- ensure_provider_match(account, provider) do
      case existing_link(workspace_id, provider) do
        nil ->
          Ash.create(WorkspaceProviderAccount, %{
            workspace_id: workspace_id,
            provider: provider,
            provider_account_id: account.id,
            share: Keyword.get(opts, :share)
          })

        link ->
          attrs =
            %{provider_account_id: account.id}
            |> maybe_put_share(opts)

          link
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update()
      end
    end
  end

  @doc """
  Detach a workspace from an account — the inverse of `attach_workspace/4`.
  Deletes the `(workspace_id, account.provider)` `WorkspaceProviderAccount`
  row, but only while it still points at *this* account: a link an operator
  has since re-pointed elsewhere is `{:error, :not_attached}`, never deleted
  out from under them.
  """
  @spec detach_workspace(String.t(), String.t()) ::
          {:ok, WorkspaceProviderAccount.t()} | {:error, :not_found | :ambiguous | :not_attached}
  def detach_workspace(workspace_id, account_ref) do
    with {:ok, _workspace} <- get_workspace(workspace_id),
         {:ok, account} <- get_account(account_ref),
         %WorkspaceProviderAccount{provider_account_id: account_id} = link
         when account_id == account.id <- existing_link(workspace_id, account.provider),
         :ok <- Ash.destroy(link) do
      {:ok, link}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_attached}
    end
  end

  defp maybe_put_share(attrs, opts) do
    if Keyword.has_key?(opts, :share) do
      Map.put(attrs, :share, Keyword.get(opts, :share))
    else
      attrs
    end
  end

  defp normalize_provider(provider) when is_atom(provider), do: {:ok, provider}

  defp normalize_provider(provider) when is_binary(provider) do
    case parse_provider(provider) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, {:invalid_provider, provider}}
    end
  end

  defp ensure_provider_match(%{provider: p}, p), do: :ok

  defp ensure_provider_match(%{provider: account_provider}, _),
    do: {:error, {:provider_mismatch, account_provider}}

  defp ensure_not_merged_away(%{merged_into_id: survivor_id}) when not is_nil(survivor_id),
    do: {:error, {:merged_away, survivor_id}}

  defp ensure_not_merged_away(%{deleted_at: at}) when not is_nil(at),
    do: {:error, :already_deleted}

  defp ensure_not_merged_away(_account), do: :ok

  defp existing_link(workspace_id, provider) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(workspace_id == ^workspace_id and provider == ^provider)
    |> Ash.read_one!()
  end

  @doc """
  Rotate an account's credential — `arb account rotate <slug>`. Inserts a new
  active `ProviderCredential` row and retires the previous active credential
  of the same `kind` (§2.5, §7.2 — rotation is an insert, never an update). A
  data operation, not automated rotation (§11's non-goals). Never logs or
  returns the secret in a loggable form: the caller gets back the created
  row, whose `secret` field is write-only and never serialized.

  `kind: :cli_credentials_path` (bd-b632tz) references the quota poller's
  dedicated Claude grant by **location**: `secret` is a config directory or
  its `.credentials.json` (normalized to the absolute file path, which must
  already hold a readable grant — `{:error, {:invalid_credentials_path,
  reason}}` otherwise), and `env_var` defaults to `CLAUDE_CONFIG_DIR`. The
  grant's tokens are never read into the row; see
  `Arbiter.Quota.GrantFile`.
  """
  @spec rotate_credential(String.t(), map()) :: {:ok, ProviderCredential.t()} | {:error, term()}
  def rotate_credential(account_ref, attrs) when is_map(attrs) do
    with {:ok, account} <- get_account(account_ref),
         :ok <- ensure_not_merged_away(account),
         {:ok, raw_secret} <- fetch_required(attrs, :secret),
         {:ok, raw_kind} <- fetch_required(attrs, :kind),
         {:ok, kind} <- parse_kind(raw_kind),
         {:ok, secret} <- normalize_secret(kind, raw_secret),
         {:ok, env_var} <- fetch_env_var(kind, attrs) do
      Arbiter.Repo.transaction(fn ->
        # Retire the current active credential of this kind *first* — the
        # partial unique index allows only one active row per
        # (account, kind), so the new insert would otherwise collide with it.
        retire_previous(account.id, kind)

        case Ash.create(ProviderCredential, %{
               provider_account_id: account.id,
               kind: kind,
               env_var: env_var,
               secret: secret,
               fingerprint: Census.fingerprint(secret),
               scopes: Map.get(attrs, :scopes) || Map.get(attrs, "scopes")
             }) do
          {:ok, credential} -> credential
          {:error, error} -> Arbiter.Repo.rollback(error)
        end
      end)
    end
  end

  @credential_kinds ~w(oauth_token api_key cli_credentials_file cli_credentials_path)

  # The env var a `:cli_credentials_path` row is filed under. It names what
  # the path is for — the `claude` CLI's config dir — but the row is never
  # projected into a spawn env (`Arbiter.Accounts.Credentials` skips the kind).
  @grant_path_env_var "CLAUDE_CONFIG_DIR"

  defp parse_kind(kind)
       when is_atom(kind) and
              kind in [:oauth_token, :api_key, :cli_credentials_file, :cli_credentials_path],
       do: {:ok, kind}

  defp parse_kind(kind) when kind in @credential_kinds, do: {:ok, String.to_existing_atom(kind)}
  defp parse_kind(kind), do: {:error, {:invalid_kind, kind}}

  defp normalize_secret(:cli_credentials_path, location) when is_binary(location) do
    case GrantFile.normalize_path(location) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {:invalid_credentials_path, reason}}
    end
  end

  defp normalize_secret(_kind, secret), do: {:ok, secret}

  defp fetch_env_var(:cli_credentials_path, attrs) do
    case fetch_required(attrs, :env_var) do
      {:ok, env_var} when is_binary(env_var) and env_var != "" -> {:ok, env_var}
      _missing_or_blank -> {:ok, @grant_path_env_var}
    end
  end

  defp fetch_env_var(_kind, attrs), do: fetch_required(attrs, :env_var)

  defp fetch_required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp retire_previous(account_id, kind) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and kind == ^kind and active == true)
    |> Ash.read!()
    |> Enum.each(&Ash.update!(&1, %{}, action: :retire))
  end

  @doc """
  Merge `from_ref` into `into_ref` — `arb account merge <from-slug> --into
  <into-slug>` (§2.5). Transactional; see `Arbiter.Accounts.Merge` for the
  per-table re-point rules.
  """
  @spec merge_accounts(String.t(), String.t()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  defdelegate merge_accounts(from_ref, into_ref), to: Merge, as: :merge

  @doc """
  Delete an account — `arb account delete <ref>` / `DELETE /api/accounts/:ref`
  (bd-agb7ai). Soft-delete by default: the row and its `usage_events`
  attribution are kept, but it is marked `deleted_at` and `enabled: false`
  (mirroring `Merge`'s `soft_delete!/2`), which hides it from
  `list_accounts/1` and every enabled-only picker. Every active credential is
  retired first — never revealed, only marked inactive.

  Refuses, with a specific reason, when the account:

    * is required by a workspace's implementer or reviewer settings
      (`{:error, {:required_by_workspace, workspace_id, roles}}`) — always, `
      :detach` included; the operator must clear the role setting first
      (`Arbiter.Accounts.ProviderSettings.remove/3`).
    * is pinned by a running task's provider routing (bd-40pzpj)
      (`{:error, {:pinned_by_task, task_id}}`).
    * is attached to a workspace at all (`{:error, {:attached, workspace_ids}}`)
      — unless `opts[:detach]` is true, in which case the links are removed as
      part of the delete.
    * would drop a workspace's only credential source while
      `enabled?/0` is true and that workspace's `worker_env` still carries a
      credential for this provider — the `Arbiter.Accounts.MissingCredentialError`
      a next dispatch would hit (`{:error, {:missing_credential_risk, workspace_id}}`).
      Not bypassed by `:detach`.

  `opts[:hard]` destroys the row outright instead — only permitted for an
  account with no `usage_events` row and no `provider_credentials` row, ever
  (`{:error, :hard_delete_blocked}` otherwise).
  """
  @spec delete_account(String.t(), keyword()) :: {:ok, ProviderAccount.t()} | {:error, term()}
  def delete_account(ref, opts \\ []) do
    hard? = Keyword.get(opts, :hard, false)
    detach? = Keyword.get(opts, :detach, false)

    with {:ok, account} <- get_account(ref),
         :ok <- ensure_not_already_gone(account),
         :ok <- ensure_not_pinned(account),
         :ok <- ensure_no_required_links(account),
         {:ok, links} <- ensure_attachments_removable(account, detach?) do
      if hard?, do: hard_delete(account, links), else: soft_delete(account, links)
    end
  end

  defp ensure_not_already_gone(%{merged_into_id: id}) when not is_nil(id),
    do: {:error, {:merged_away, id}}

  defp ensure_not_already_gone(%{deleted_at: at}) when not is_nil(at),
    do: {:error, :already_deleted}

  defp ensure_not_already_gone(_account), do: :ok

  defp ensure_not_pinned(%{id: id}) do
    Issue
    |> Ash.Query.filter(implementer_account_id == ^id and state != :closed)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [task] -> {:error, {:pinned_by_task, task.id}}
      [] -> :ok
    end
  end

  defp ensure_no_required_links(%{id: id}) do
    id
    |> account_links()
    |> Enum.find(&(&1.implementer_position || &1.reviewer_position))
    |> case do
      nil -> :ok
      link -> {:error, {:required_by_workspace, link.workspace_id, required_roles(link)}}
    end
  end

  defp required_roles(link) do
    [{link.implementer_position, :implementer}, {link.reviewer_position, :reviewer}]
    |> Enum.filter(fn {position, _role} -> not is_nil(position) end)
    |> Enum.map(fn {_position, role} -> role end)
  end

  defp ensure_attachments_removable(account, detach?) do
    links = account_links(account.id)

    cond do
      links == [] -> {:ok, []}
      not detach? -> {:error, {:attached, Enum.map(links, & &1.workspace_id)}}
      true -> ensure_no_missing_credential_risk(account, links)
    end
  end

  defp ensure_no_missing_credential_risk(account, links) do
    links
    |> Enum.find(&missing_credential_risk?(&1, account))
    |> case do
      nil -> {:ok, links}
      link -> {:error, {:missing_credential_risk, link.workspace_id}}
    end
  end

  # §7.5's read flip: a workspace whose `worker_env` still carries this provider's credential key resolves it
  # solely through this link (`Arbiter.Accounts.Credentials.workspace_pairs/1`
  # — cardinality is one account per (workspace, provider), so there is never
  # a second link to fall back to). Removing the link would raise
  # `Arbiter.Accounts.MissingCredentialError` at the workspace's next spawn.
  defp missing_credential_risk?(link, account) do
    workspace_carries_credential?(link.workspace_id, account.provider)
  end

  defp workspace_carries_credential?(workspace_id, provider) do
    case get_workspace(workspace_id) do
      {:ok, workspace} ->
        provider_str = to_string(provider)

        workspace
        |> Workspace.worker_env_keys()
        |> Enum.any?(fn %{name: name} ->
          match?(%{provider: ^provider_str}, Census.credential_keys()[name])
        end)

      {:error, _} ->
        false
    end
  end

  defp account_links(account_id) do
    WorkspaceProviderAccount
    |> Ash.Query.filter(provider_account_id == ^account_id)
    |> Ash.read!()
  end

  defp soft_delete(account, links) do
    Arbiter.Repo.transaction(fn ->
      Enum.each(links, &Ash.destroy!/1)
      retire_active_credentials(account.id)
      account |> Ash.Changeset.for_update(:soft_delete, %{}) |> Ash.update!()
    end)
  rescue
    error -> {:error, error}
  end

  defp retire_active_credentials(account_id) do
    ProviderCredential
    |> Ash.Query.filter(provider_account_id == ^account_id and active == true)
    |> Ash.read!()
    |> Enum.each(&Ash.update!(&1, %{}, action: :retire))
  end

  defp hard_delete(account, links) do
    with :ok <- ensure_hard_deletable(account) do
      Arbiter.Repo.transaction(fn ->
        Enum.each(links, &Ash.destroy!/1)
        Ash.destroy!(account)
        account
      end)
    end
  rescue
    error -> {:error, error}
  end

  defp ensure_hard_deletable(account) do
    usage_count = Event |> Ash.Query.filter(provider_account_id == ^account.id) |> Ash.count!()

    credential_count =
      ProviderCredential |> Ash.Query.filter(provider_account_id == ^account.id) |> Ash.count!()

    if usage_count == 0 and credential_count == 0 do
      :ok
    else
      {:error, :hard_delete_blocked}
    end
  end

  @doc "Resolve a workspace by UUID id (`arb account attach`'s `<workspace>` arg)."
  @spec get_workspace(String.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def get_workspace(id) do
    if uuid?(id) do
      case Ash.get(Workspace, id) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, _} -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end
end
