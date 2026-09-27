defmodule ArbiterWeb.Api.QuotaController do
  @moduledoc """
  `GET /api/quota` — the current quota state for a workspace. Backs `arb quota`.

  Resolves the target workspace from `?workspace=<id|name>`, falling back to
  the installation default.

  A pure DB read (bd-ajh7bd): every provider is read from its persisted quota
  table, kept fresh by the background `Arbiter.Quota.CloudProbe` polling
  (`/api/oauth/usage` for Anthropic, and similar endpoints for Codex /
  Antigravity). No provider is fetched live here, so a dashboard/CLI load
  carries no request-time latency or rate-limit exposure.

  `quotas` carries every tracked provider as the uniform view shape (each
  including its own `provider` field) — `claude` is kept as a top-level key too
  for `arb quota` and other existing consumers of the pre-multi-provider shape.

  Since P5 (`docs/provider-account-design.md` §6) the quota rows are keyed by
  **provider account**, and `?workspace=` is the lookup shorthand that
  resolves to that workspace's account (one per provider). Each `quotas`
  entry therefore carries `account` and `workspaces` — the account it belongs
  to and every workspace metered under it, with that workspace's own spend —
  and `workspace` names the workspace the lookup came in through.
  `workspace_id` is retained for one release as its deprecated alias. The
  top-level `account` / `workspaces` describe the headline (Claude) provider.

  `?account=<id|provider:slug|slug>` (P10, §8) goes straight to the account
  instead of through a workspace — the same ref shapes `arb account` itself
  accepts. `workspace_id` / `workspace` are `null` in this shape (there was
  no workspace lookup), and only that account's own provider carries real
  data; the rest are `null`, the same as an unauthenticated CLI. Takes
  priority over `?workspace=` when both are given.

  `account_policy` / `policy_binding` (bd-c7ll4t) describe the headline
  account's own `quota_config` (mode, ceilings) and, under `?workspace=`,
  which side of `min(account, workspace)` is currently binding each flat
  ceiling — `:account`, `:workspace`, or `:default`. With `:provider_accounts_enabled`
  on, an account's flat ceiling can bind tighter than a paced/looser
  workspace's own config silently (bd-5ps98m); this is how `arb quota` says
  so instead of only ever printing "not quota-held".

    * `claude` — the latest polled snapshot, including per-model weekly breakdowns
      and overage spend; `null` before the first poll.
    * `codex` — the persisted OpenAI session/weekly-window snapshot (a distinct
      shape, so it stays a top-level key rather than joining `quotas`); `null`
      (with a `codex_message`) until the Codex probe has stored one.
    * `gemini` / `antigravity` — the persisted per-model Cloud Code Assist
      snapshot (bd-57ukgb), each `null` until that CLI is authenticated and
      probed on this host.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  def show(conn, %{"account" => account_ref}) when is_binary(account_ref) and account_ref != "" do
    show_by_account(conn, account_ref)
  end

  def show(conn, params) do
    case resolve_workspace_id(Map.get(params, "workspace")) do
      {:ok, ws_id} ->
        accounts = Quota.account_ids(ws_id)
        codex = Quota.Codex.serialize_latest(accounts["codex"])

        # Every `account`/`workspaces` block below carries each workspace's
        # 30-day spend, read off `Arbiter.Quota.SpendCache`'s memoized
        # grouped aggregate (bd-4p6pw7) rather than a scan per workspace, so
        # the memo is built here once and threaded through all three calls.
        spend = Quota.spend_cache(accounts)

        # §6's `--json` gains `account` / `workspaces` at the top level. They
        # describe the **headline** (Claude) provider's account; a workspace
        # may sit on a different account per provider, so each `quotas` entry
        # carries its own pair too.
        headline = Quota.account_fields(accounts["claude"], "claude", spend)
        headline_workspace = safe_workspace(ws_id)

        policy =
          Quota.policy_fields(
            Arbiter.Accounts.Resolver.get(accounts["claude"]),
            headline_workspace
          )

        render(conn, :show,
          workspace_id: ws_id,
          workspace: workspace_view(ws_id),
          requested_workspace: Map.get(params, "workspace"),
          claude:
            Quota.serialize(accounts["claude"], "claude",
              workspace_id: ws_id,
              spend_cache: spend
            ),
          quotas: Quota.list_serialized_for_workspace(ws_id, spend_cache: spend),
          account: headline[:account],
          workspaces: headline[:workspaces],
          account_policy: policy[:account_policy],
          policy_binding: policy[:policy_binding],
          effective_policy: policy[:effective],
          codex: codex,
          codex_message: Quota.codex_absence_message(codex),
          # bd-1fpjgx: mirrors `claude`'s `credentials_expired` field, sourced
          # the same way — live off `CredentialWatchdog`'s held state, not the
          # persisted snapshot, so it reflects the free 401-streak / agy-exit
          # signal `CloudProbe` now feeds it for these adapters too.
          codex_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Codex),
          antigravity: Quota.CloudCode.serialize_latest(accounts["antigravity"], "antigravity"),
          gemini_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Gemini)
        )

      {:error, message} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{type: "not_found", message: message}})
    end
  end

  # P10 (`docs/provider-account-design.md` §8, bd-icwk2k): `?account=` goes
  # straight to the account instead of through a workspace — a UUID, a
  # `"provider:slug"` ref, or a bare unambiguous slug, the same refs
  # `arb account` itself accepts. Only that account's own provider carries
  # real data; the others stay `nil`, same as an unauthenticated CLI.
  defp show_by_account(conn, account_ref) do
    case Arbiter.Accounts.get_account(account_ref) do
      {:ok, account} ->
        provider = Atom.to_string(account.provider)
        spend = Quota.spend_cache(account.id)
        fields = Quota.account_fields(account.id, provider, spend)

        codex = if provider == "codex", do: Quota.Codex.serialize_latest(account.id)
        policy = Quota.policy_fields(account, nil)

        render(conn, :show,
          workspace_id: nil,
          workspace: nil,
          requested_workspace: nil,
          claude:
            if(provider == "claude",
              do: Quota.serialize(account.id, "claude", spend_cache: spend)
            ),
          quotas: Quota.list_serialized(account.id, spend_cache: spend),
          account: fields[:account],
          workspaces: fields[:workspaces],
          account_policy: policy[:account_policy],
          policy_binding: policy[:policy_binding],
          effective_policy: policy[:effective],
          codex: codex,
          codex_message: Quota.codex_absence_message(codex),
          codex_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Codex),
          antigravity:
            if(provider == "antigravity",
              do: Quota.CloudCode.serialize_latest(account.id, "antigravity")
            ),
          gemini_credentials_expired:
            Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Gemini)
        )

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: %{type: "not_found", message: "account #{inspect(account_ref)} not found"}
        })

      {:error, :ambiguous} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            type: "ambiguous",
            message: "account #{inspect(account_ref)} is ambiguous; use \"provider:slug\""
          }
        })
    end
  end

  defp workspace_view(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{id: id, name: name}} -> %{id: id, name: name}
      _ -> %{id: ws_id, name: nil}
    end
  rescue
    _ -> %{id: ws_id, name: nil}
  end

  defp safe_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Explicit `?workspace=` (id, then name) wins; else the installation default.
  defp resolve_workspace_id(nil), do: default_workspace_id()
  defp resolve_workspace_id(""), do: default_workspace_id()

  defp resolve_workspace_id(ref) do
    with :error <- by_id(ref), :error <- by_name(ref) do
      {:error, "workspace #{inspect(ref)} not found"}
    end
  end

  defp by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{id: id}} -> {:ok, id}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp default_workspace_id do
    case Quota.default_workspace_id() do
      {:ok, id} -> {:ok, id}
      {:error, :no_workspaces} -> {:error, "no workspaces exist on this installation"}
      {:error, _} -> {:error, "no default workspace; pass ?workspace=<id>"}
    end
  end
end
