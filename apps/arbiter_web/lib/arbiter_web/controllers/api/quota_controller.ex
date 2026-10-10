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
  ceiling — `:account`, `:workspace`, or `:default`. An account's flat
  ceiling can bind tighter than a paced/looser workspace's own config
  silently (bd-5ps98m); this is how `arb quota` says so instead of only ever
  printing "not quota-held".

    * `claude` — the latest polled snapshot, including per-model weekly breakdowns
      and overage spend; `null` before the first poll.
    * `codex` — the persisted OpenAI session/weekly-window snapshot (a distinct
      shape, so it stays a top-level key rather than joining `quotas`); `null`
      (with a `codex_message`) until the Codex probe has stored one.
    * `gemini` / `antigravity` — the persisted per-model Cloud Code Assist
      snapshot (bd-57ukgb), each `null` until that CLI is authenticated and
      probed on this host.
    * `paused_providers` — every provider / account an operator paused
      (`arb provider pause`, bd-5ef587) with who, when and why.
    * `budget` (DC5, bd-2c2a4g) — one block per account (`account`, `account_id`,
      `mode`, `decides`, `pools`): each provider pool's concurrency budget with its
      reason, labelled `shadow` until `scheduler_admission` is `enforce`
      (`Arbiter.Board.CapacityView`).
    * `held_dispatches` — every dispatch the workspace's quota gate is holding
      (`Arbiter.Workflows.DispatchQueue.serialize_held/1`): the task, what it
      will do when it drains (a ReviewGate fix round, a resume, a dispatch),
      the provider it was held on and the gate's reason (bd-6omte4). The
      per-provider gating lines describe a provider's snapshot; this is what
      the gate actually held, whichever provider and model bucket it read. `[]`
      under `?account=`, which names no workspace queue.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Quota.Snapshot
  alias Arbiter.Tasks.Workspaces

  action_fallback(ArbiterWeb.Api.FallbackController)

  def show(conn, %{"account" => account_ref}) when is_binary(account_ref) and account_ref != "" do
    show_by_account(conn, account_ref)
  end

  def show(conn, params) do
    # The quota view is shaped around ONE workspace, so an omitted `workspace`
    # means the installation default (`Workspaces.resolve_default/2`) — the
    # response echoes the resolved `workspace_id`. A bound token stays confined.
    case Workspaces.resolve_default(conn.assigns[:mcp_scope], Workspaces.arg(params)) do
      {:ok, ws_id} ->
        render(conn, :show, data: Snapshot.for_workspace(ws_id, Workspaces.arg(params)))

      {:error, _} = error ->
        error
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
        render(conn, :show, data: Snapshot.for_account(account))

      {:error, :not_found} ->
        {:error, {:not_found, "account #{inspect(account_ref)} not found"}}

      # The same ambiguity `/api/usage` and `/api/accounts` report.
      {:error, :ambiguous} ->
        {:error,
         {:invalid_request, "account #{inspect(account_ref)} is ambiguous; use \"provider:slug\"",
          %{}}}
    end
  end
end
