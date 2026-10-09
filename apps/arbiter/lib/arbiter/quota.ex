defmodule Arbiter.Quota do
  @moduledoc """
  Ash domain + public API for per-**account** Anthropic quota state
  (bd-5boun6; re-keyed off the workspace by P5, bd-3yokey).

  `get/2` / `serialize/2` read quota snapshots for the MCP `quota_get` tool,
  the `GET /api/quota` endpoint, and `arb quota`.

  ## Quota source: polling + archived header capture

  The primary source is `capture_oauth_usage/2`, which consumes Anthropic's
  polled `/api/oauth/usage` endpoint snapshot, driven by `Arbiter.Quota.CloudProbe`.
  This allows the dispatch gate to work on a fleet that is quota-held or idle,
  with current data. Per-model weekly breakdowns and account overage spend are
  available only through this endpoint.

  `capture/3` is now dormant / archival-only (bd-7cvh8z): it consumed
  `anthropic-ratelimit-unified-*` response headers from worker traffic, but
  the Anthropic proxy that was the sole caller was deleted once endpoint polling
  became the unified architecture across all providers. The function remains
  for compatibility with any offline migration workflows, but produces no
  in-production quota updates.

  Each write stamps `capture_source` (`"headers"` / `"oauth_poll"`, see
  `header_source/0` and `oauth_poll_source/0`) so a row says which one
  produced it — `arb quota` prints it, and
  `Arbiter.Quota.Gate.staleness_threshold_seconds/1` keys the staleness margin
  off it, because the polled source has a far tighter request budget than
  header capture ever did.

  ## Keyed by the provider account (P5, `docs/provider-account-design.md` §6)

  Every provider's rate limit is enforced per *account*, so the read API here
  takes a `provider_account_id`, not a workspace: `latest/2`,
  `latest_for_provider/2`, `serialize/3`, `list_latest/1`,
  `provider_spend/1` and `capture_oauth_usage/2` all key on the account.

  A caller holding only a workspace resolves it first —
  `account_id/2` (a pure read, `nil` when the workspace has no account) or
  `ensure_account_id/2` (write paths, which provision rather than drop the
  reading). Workspace-flavoured *writes* — `capture/3`,
  `capture_oauth_usage_for_group/2` — keep their workspace argument and do
  that hop themselves, so a spawn's call site is unchanged.
  """

  use Ash.Domain

  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.GrantFile
  alias Arbiter.Quota.OAuthUsage
  alias Arbiter.Quota.Pace
  alias Arbiter.Quota.SpendCache
  alias Arbiter.Tasks.Workspace
  require Ash.Query

  resources do
    resource Arbiter.Quota.AnthropicQuota
    resource Arbiter.Quota.CodexQuota
    resource Arbiter.Quota.CodexQuotaSnapshot
    resource Arbiter.Quota.GoogleQuota
    resource Arbiter.Quota.QuotaSnapshot
  end

  @default_provider "claude"

  @typedoc """
  A `%{workspace_id => workspace_spend/1}` memo, built by `spend_cache/1` and
  threaded through `account_fields/3` so one request's worth of quota views
  scans the usage ledger once per workspace rather than once per
  workspace-and-provider.
  """
  @type spend_cache :: %{optional(String.t()) => %{optional(String.t()) => float()}}

  # `capture_source` provenance markers (bd-b0zody). Both sources write the
  # same primary columns during the overlap window, so the row records which
  # one last wrote it — `arb quota` prints it, and `Arbiter.Quota.Gate` picks
  # its staleness threshold off it.
  @header_source "headers"
  @oauth_poll_source "oauth_poll"

  @doc "The `capture_source` value `capture/3` (header capture) stamps."
  @spec header_source() :: String.t()
  def header_source, do: @header_source

  @doc "The `capture_source` value the `/api/oauth/usage` poll stamps."
  @spec oauth_poll_source() :: String.t()
  def oauth_poll_source, do: @oauth_poll_source

  # Cost pricing (bd-ajh7bd). Rather than invent a second price table, we reuse
  # the real per-session `cost_usd` already recorded in the `Arbiter.Usage`
  # ledger (which prices Claude off the CLI's own figure and Gemini via
  # `Arbiter.Agents.Gemini.Pricing`) and roll a trailing window of actual spend
  # up per provider, so `arb quota` / the `/usage` page can show dollars spent
  # alongside utilization %.
  #
  # The ledger keys spend by an inferred provider ("claude" / "gemini" /
  # "openai"), which doesn't 1:1 match the quota provider codes — this maps each
  # quota code to the ledger key(s) that roll up under it. Antigravity has no
  # distinct ledger key (it shares Gemini/Claude/GPT models with other surfaces,
  # so its spend can't be cleanly attributed) → no cost figure.
  @ledger_providers %{
    "claude" => ["claude"],
    "codex" => ["openai"],
    "antigravity" => []
  }

  # Trailing window over which per-provider spend is summed for the cost figure.
  @cost_window_days 30

  # Providers hidden from the status-bar quota chip and `/usage`. Empty since
  # all providers with sufficient parity are now shown. `Arbiter.Quota.Visibility`
  # applies this list last, over auto-detection and the install-wide override alike.
  # `GET /api/quota`, `arb quota` and `quota_get` never read it — they still
  # report every provider, hidden or not.
  @hidden_providers []

  @doc """
  Quota provider codes hidden from the status bar and `/usage` — see
  `@hidden_providers`. The `:arbiter, :quota_hidden_providers` app env
  replaces the list, for tests that exercise a provider still hidden here.
  """
  @spec hidden_providers() :: [String.t()]
  def hidden_providers,
    do: Application.get_env(:arbiter, :quota_hidden_providers, @hidden_providers)

  # ---- dispatch gate (bd-7cd38f) -----------------------------------------

  @doc """
  Resolve the `Arbiter.Quota.Gate` implementation for a workspace.

  Precedence:

    1. The `:arbiter, :quota` `:gate` app-env override — a kill switch that
       can only force a *core* gate: `Arbiter.Quota.Gate.Throttle` or
       `Arbiter.Quota.Gate.Continue` (to bypass throttling entirely). Any other
       value is ignored: it can never install a policy (seams #6), so a gate
       is installed only through the `:quota_gate` registry and selected
       per workspace by rule 2.
    2. The workspace's `config["quota"]["gate"]`, a key registered on the
       `:quota_gate` seam (`Arbiter.Extensions`) — how an installed
       `Arbiter.Extension`'s gate is selected per workspace. A key that names
       nothing registered (an extension since uninstalled) is skipped, so the
       workspace degrades to the next rule rather than failing to dispatch.
    3. Otherwise the workspace's resolved `on_exhaustion` mode
       (`Workspace.quota_on_exhaustion/1`, which itself layers per-workspace over
       global over the hardcoded `:throttle`): `:continue` → `Gate.Continue`,
       else `Gate.Throttle`.

  Rule 1 is install-global and beats rule 2, but only between core gates; it is
  not a registration path and extensions never set it.
  """
  @core_gates [Arbiter.Quota.Gate.Throttle, Arbiter.Quota.Gate.Continue]

  @spec gate_for_workspace(Workspace.t() | nil) :: module()
  def gate_for_workspace(workspace) do
    case Application.get_env(:arbiter, :quota, [])[:gate] do
      mod when mod in @core_gates ->
        mod

      _ ->
        registered_gate(workspace) || on_exhaustion_gate(workspace)
    end
  end

  defp registered_gate(%Workspace{config: config}) when is_map(config) do
    case Arbiter.Extensions.fetch(:quota_gate, get_in(config, ["quota", "gate"])) do
      {:ok, gate} -> gate
      :error -> nil
    end
  end

  defp registered_gate(_workspace), do: nil

  defp on_exhaustion_gate(workspace) do
    case Workspace.quota_on_exhaustion(workspace) do
      :continue -> Arbiter.Quota.Gate.Continue
      _ -> Arbiter.Quota.Gate.Throttle
    end
  end

  @doc """
  Whether the workspace's resolved quota gate is `:continue` mode — the
  `dispatch/2` seam will let work through past the cap (paid overage) rather
  than holding it.

  Shared by `Arbiter.Board.Snapshot.quota_hold/1` (bd-5j6nmn) so the board and
  Autopilot's one-per-tick promotion gate defer to the same
  seam-resolved mode — including the `:arbiter, :quota, :gate` test/kill-switch
  override — instead of each independently re-deriving `on_exhaustion`.
  """
  @spec continue_mode?(Workspace.t() | nil) :: boolean()
  def continue_mode?(workspace) do
    gate_for_workspace(workspace) == Arbiter.Quota.Gate.Continue
  end

  # Quota-provider code for each dispatchable agent type / provider alias. The
  # gate resolves the provider a dispatch will actually run on and reads that
  # provider's snapshot table through `latest_for_provider/2` (bd-2mpo3f).
  #
  # `"gemini"` (the agent-type alias, as opposed to the concrete
  # `"antigravity"` code) is deliberately absent here — it is resolved
  # dynamically in `provider_code/1` via `Arbiter.Agents.Gemini.resolve_executable/0`
  # (bd-7qj58o) rather than pinned to a static code, so the gate always reads
  # the quota table matching the CLI that will actually run.
  @provider_codes %{
    "claude" => "claude",
    "anthropic" => "claude",
    "codex" => "codex",
    "openai" => "codex",
    "antigravity" => "antigravity",
    "grok" => "grok"
  }

  @doc """
  The latest persisted quota snapshot for `provider_account_id` on
  `provider`, read from that provider's own table (bd-2mpo3f):

    * `:claude` → `AnthropicQuota` (OAuth polling + header capture from responses)
    * `:codex` → `CodexQuota` (`Arbiter.Quota.CloudProbe` / `Quota.Codex.fetch/2`)
    * `:gemini` (when agy runs it) / `:antigravity` → `GoogleQuota` (`Arbiter.Quota.CloudCode`)
    * `:grok` → no table: the ledger estimate `Arbiter.Quota.GrokLedger.snapshot/1`
      (a `Arbiter.Quota.Gate.Snapshot`, bd-cwq8b0)

  Accepts the agent-type atom (`:claude` / `:codex` / `:gemini`) or the quota
  provider code string. Returns `nil` for an unknown provider or when nothing
  has been captured yet — the gate's fail-open input.
  """
  @spec latest_for_provider(String.t() | nil, atom() | String.t()) :: struct() | nil
  # bd-cwq8b0: grok has no quota table and no pollable endpoint; its snapshot is
  # the ledger estimate (`Arbiter.Quota.GrokLedger`), not a stored row. The
  # free tier's cap belongs to the one xAI account, so the account id is not
  # consulted.
  def latest_for_provider(_account_id, provider) when provider in [:grok, "grok"],
    do: Arbiter.Quota.GrokLedger.snapshot()

  def latest_for_provider(account_id, provider) when is_binary(account_id) do
    case provider_code(provider) do
      "claude" -> latest(account_id, "claude")
      "codex" -> Arbiter.Quota.Codex.latest(account_id, "codex")
      "antigravity" -> CloudCode.latest(account_id, "antigravity")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def latest_for_provider(_account_id, _provider), do: nil

  @doc """
  `latest_for_provider/2` for a caller that holds a workspace rather than an
  account — the shape the dispatch gate, the board and `Dispatch` still speak
  (their own re-key is P7/P8). `nil` when the workspace has no account for
  that provider, which is the gate's existing fail-open input.
  """
  @spec latest_for_workspace(String.t() | nil, atom() | String.t()) :: struct() | nil
  def latest_for_workspace(_workspace_id, provider) when provider in [:grok, "grok"],
    do: Arbiter.Quota.GrokLedger.snapshot()

  def latest_for_workspace(workspace_id, provider) do
    case account_id(workspace_id, provider) do
      nil -> nil
      id -> latest_for_provider(id, provider)
    end
  end

  @doc """
  The provider account `workspace_id` is metered under for `provider`, or
  `nil`. A pure read — see `Arbiter.Accounts.Resolver`.
  """
  @spec account_id(String.t() | nil, atom() | String.t() | nil) :: String.t() | nil
  def account_id(workspace_id, provider),
    do: Resolver.account_id(workspace_id, provider_code(provider) || provider)

  @doc """
  `account_id/2`, provisioning an account when the install has none — the
  form every quota *write* uses, because a reading has nowhere to go without
  one.
  """
  @spec ensure_account_id(String.t() | nil, atom() | String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def ensure_account_id(workspace_id, provider),
    do: Resolver.ensure_account_id(workspace_id, provider_code(provider) || provider)

  @doc "Every provider account this workspace is linked to, `%{provider => account_id}`."
  @spec account_ids(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def account_ids(workspace_id), do: Resolver.account_ids(workspace_id)

  @doc """
  Canonical quota provider code for an agent type / provider alias, or `nil`
  when the provider has no tracked quota.

  `"gemini"` is resolved dynamically (bd-7qj58o): it reuses
  `Arbiter.Agents.Gemini.resolve_executable/0` — the same PATH probe the
  adapter itself uses to pick a CLI to spawn — to return `"antigravity"` when
  `agy` is what will actually run, and `nil` otherwise: the upstream Gemini
  CLI provider (`"gemini_cli"`) was dropped in bd-ac53wz, so it has no quota
  code, account or snapshot any more. A caller that already names the
  concrete `"antigravity"` code gets it back verbatim — only the ambiguous
  agent-type alias is resolved live.
  """
  @spec provider_code(atom() | String.t() | nil) :: String.t() | nil
  def provider_code(provider) when is_atom(provider) and not is_nil(provider),
    do: provider_code(Atom.to_string(provider))

  def provider_code("gemini"), do: gemini_provider_code()
  def provider_code(provider) when is_binary(provider), do: Map.get(@provider_codes, provider)
  def provider_code(_), do: nil

  defp gemini_provider_code do
    case Arbiter.Agents.Gemini.resolve_executable() do
      {:ok, {:agy, _path}} -> "antigravity"
      _ -> nil
    end
  end

  @doc """
  Best-effort resolution of the quota provider a workspace's dispatches run
  on absent a per-dispatch override — the workspace's default agent provider
  (`Arbiter.Agents.for_workspace/1`), as an atom.

  Used by the board's dispatch gate (`Arbiter.Board.Snapshot.quota_hold/1`,
  bd-5j6nmn) and the `dispatch/2` seam, so both read the same provider's
  snapshot for a given workspace. Any load failure or unresolvable id falls back to `:claude`
  (the historical default).
  """
  @spec default_provider(Workspace.t() | String.t() | nil) :: atom()
  def default_provider(%Workspace{} = workspace) do
    String.to_existing_atom(Arbiter.Agents.for_workspace(workspace).provider())
  rescue
    _ -> :claude
  end

  def default_provider(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> default_provider(ws)
      _ -> :claude
    end
  rescue
    _ -> :claude
  catch
    :exit, _ -> :claude
  end

  def default_provider(_), do: :claude

  # ---- capture -----------------------------------------------------------

  @doc """
  Upsert a quota snapshot for `workspace_id` from a list of HTTP response
  `headers` (`[{name, value}]`, as Finch/Plug deliver them).

  Returns `{:ok, quota}` when the headers carried any
  `anthropic-ratelimit-unified-*` value, `:noop` when they didn't (so health
  checks and non-Anthropic responses are silently skipped), and
  `{:error, reason}` if the upsert fails.

  A `nil` / blank `workspace_id` is resolved to the installation default
  workspace so a workspace-agnostic credential probe still records state, and
  from there to the provider account that workspace meters under (P5) — the
  row itself is keyed by the account.
  """
  @spec capture(String.t() | nil, [{String.t(), String.t()}], keyword()) ::
          {:ok, AnthropicQuota.t()} | :noop | {:error, term()}
  def capture(workspace_id, headers, opts \\ []) when is_list(headers) do
    case parse_unified_headers(headers) do
      attrs when map_size(attrs) == 0 ->
        :noop

      attrs ->
        provider = Keyword.get(opts, :provider, @default_provider)

        with {:ok, ws_id} <- resolve_workspace_id(workspace_id),
             {:ok, account_id} <- ensure_account_id(ws_id, provider) do
          full =
            attrs
            |> Map.put(:provider_account_id, account_id)
            |> Map.put(:provider, provider)
            |> Map.put(:capture_source, @header_source)
            |> Map.put_new(:captured_at, DateTime.utc_now() |> DateTime.truncate(:second))

          require Logger

          Logger.debug(
            "Quota.capture: account=#{account_id}, provider=#{provider}, status_5h=#{Map.get(attrs, :status_5h)}, utilization_5h=#{Map.get(attrs, :utilization_5h)}, captured_at=#{Map.get(full, :captured_at)}"
          )

          result =
            AnthropicQuota
            |> Ash.Changeset.for_create(:upsert, full)
            |> Ash.create()

          with {:ok, quota} <- result do
            Arbiter.Quota.History.record(account_id, quota)
            broadcast_quota_update(account_id, quota)
          end

          result
        end
    end
  end

  # Broadcast a quota update, carrying the uniform view map (not the raw
  # resource struct) so every provider's live update lands on the LiveView in
  # the same shape `list_latest/1` returns.
  #
  # The topic is still per workspace — that is what the dashboard subscribes
  # to, and a workspace is what a page is looking at — so one account-keyed
  # write fans out to every workspace metered under that account (P5).
  defp broadcast_quota_update(account_id, %AnthropicQuota{} = quota) do
    Arbiter.Quota.QuotaCache.invalidate_for_account(account_id)
    Arbiter.Quota.Broadcast.quota_updated(account_id, view(quota))
  end

  @doc """
  Latest quota snapshot for `provider_account_id` + `provider`, or `nil` if
  none has been captured yet.
  """
  @spec latest(String.t() | nil, String.t()) :: AnthropicQuota.t() | nil
  def latest(account_id, provider \\ @default_provider)

  def latest(account_id, provider) when is_binary(account_id) do
    AnthropicQuota
    |> Ash.Query.filter(provider_account_id == ^account_id and provider == ^provider)
    |> Ash.read_one()
    |> case do
      {:ok, %AnthropicQuota{} = q} -> q
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # A caller whose workspace has no account for this provider yet (§6's
  # backfill has not reached it) reads as "nothing captured", which is the
  # same fail-open input a missing row already produced.
  def latest(_account_id, _provider), do: nil

  @doc """
  Serialize the latest snapshot for `provider_account_id` into the public map
  shape (string-friendly, ISO-8601 timestamps), or `nil` when none exists.

  `:workspace_id` names the workspace whose gate config annotates the
  `gating_*` fields (for backward compatibility with `arb quota --workspace`).
  When none is given, the account's alphabetically-first workspace stands in.

  `:spend_cache` optionally supplies a `spend_cache/1` memo so a caller that
  also lists the other providers pays for the ledger scan once — see
  `account_fields/3`.
  """
  @spec serialize(String.t() | nil, String.t(), keyword()) :: map() | nil
  def serialize(account_id, provider \\ @default_provider, opts \\ []) do
    case latest(account_id, provider) do
      nil ->
        nil

      %AnthropicQuota{} = q ->
        q
        |> serialize_quota()
        |> Map.merge(gating_fields(q, Resolver.get(account_id), gate_workspace(account_id, opts)))
        |> Map.merge(account_fields(account_id, provider, Keyword.get(opts, :spend_cache, %{})))
    end
  end

  @doc """
  The account's own quota policy, plus which side of `min(account,
  workspace)` binds each flat ceiling (bd-c7ll4t) — an account whose flat
  threshold bound tighter than a paced/looser workspace used to be invisible
  (bd-5ps98m: `arb quota` only ever printed "not quota-held"). Provider
  agnostic — unlike `serialize/3` (Claude-only), this works off the account
  and workspace structs directly, so `GET /api/quota?account=` can show it for
  any provider's account.

  `workspace` is `nil` for the `?account=` lookup (no workspace in play, so
  `policy_binding` only ever reads `:account` or `:default`).

  `effective` carries the ceiling actually in force for each key right now
  (bd-c7ll4t) — the paced-aware number `arb quota --workspace` prints
  instead of the account's raw flat setting, computed from the account's own
  latest quota snapshot's `reset_at`s (via `Gate.window_seconds/2` and
  `Pace.elapsed_seconds/3`) when one exists; with no snapshot yet, a paced
  side falls back exactly like the gate's own dispatch-time fallback.
  """
  @spec policy_fields(ProviderAccount.t() | nil, Workspace.t() | nil) :: map()
  def policy_fields(account, workspace) do
    elapsed = elapsed_fractions(account)

    %{
      account_policy: Gate.account_policy_summary(account),
      policy_binding: %{
        throttle_threshold:
          Gate.binding_side({account, workspace}, :throttle_threshold,
            elapsed: elapsed.throttle_threshold
          ),
        weekly_threshold:
          Gate.binding_side({account, workspace}, :weekly_threshold,
            elapsed: elapsed.weekly_threshold
          )
      },
      effective: %{
        throttle_threshold:
          Gate.effective_threshold({account, workspace}, :throttle_threshold,
            elapsed: elapsed.throttle_threshold
          ),
        weekly_threshold:
          Gate.effective_threshold({account, workspace}, :weekly_threshold,
            elapsed: elapsed.weekly_threshold
          )
      }
    }
  end

  # The elapsed fraction of each window right now, read off the account's own
  # latest quota snapshot (any provider — `Snapshot.normalize/1` projects
  # `reset_at` / `secondary_reset_at` the same way regardless of table) so a
  # paced side of `min(account, workspace)` resolves to its true
  # `max(floor, elapsed)` ceiling rather than always falling back to a flat
  # setting it has stopped using. `nil` for either window when there is no
  # account, no snapshot yet, or that window's length/`reset_at` is unknown —
  # `Gate.binding_side/3` / `effective_threshold/3` fall back gracefully.
  defp elapsed_fractions(nil), do: %{throttle_threshold: nil, weekly_threshold: nil}

  defp elapsed_fractions(%ProviderAccount{} = account) do
    now = DateTime.utc_now()
    snapshot = Snapshot.normalize(latest_for_provider(account.id, account.provider))

    %{
      throttle_threshold:
        window_elapsed(
          snapshot && snapshot.window_label,
          snapshot && snapshot.reset_at,
          account,
          now
        ),
      weekly_threshold:
        window_elapsed(
          snapshot && snapshot.secondary_window_label,
          snapshot && snapshot.secondary_reset_at,
          account,
          now
        )
    }
  end

  defp window_elapsed(nil, _reset_at, _account, _now), do: nil
  defp window_elapsed(_label, nil, _account, _now), do: nil

  defp window_elapsed(label, reset_at, account, now) do
    seconds = Gate.window_seconds(label, account)
    Pace.elapsed_seconds(reset_at, seconds, now) |> Pace.elapsed_fraction(seconds)
  end

  defp gate_workspace(account_id, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws_id when is_binary(ws_id) -> safe_workspace(ws_id)
      _ -> account_id |> Resolver.workspaces() |> List.first()
    end
  end

  # Which window (if any) is currently gating dispatch for this workspace, as
  # `arb quota` / the `quota_get` MCP tool render it (bd-1tuxv8). Before this,
  # both surfaces showed the 5h and 7d numbers side by side with no indication
  # that only the 5h one was ever consulted — the coordinator read the 7d row as
  # the thing holding Autopilot back when the gate never looked at it.
  defp gating_fields(%AnthropicQuota{} = q, account, workspace) do
    case account_pause(account) do
      # bd-aw325c: a paused provider/account is refused at dispatch (the pause
      # gate answers `{:quota_held, id}` too, and `force_quota` does not lift
      # it), so the report has to say so rather than "none".
      %{} = pause ->
        %{
          gating_window: "paused",
          gating_reason:
            "held — #{account.provider} paused: #{pause.reason || "no reason given"}",
          gating_workspaces: []
        }

      nil ->
        base =
          if Arbiter.Quota.continue_mode?(workspace),
            # `:continue` workspaces dispatch past the cap by design, so no
            # window gates them — mirroring `Board.Snapshot.quota_hold/1`.
            do: %{gating_window: nil, gating_reason: nil},
            else: gating_for(q, account, workspace)

        Map.put(base, :gating_workspaces, gating_workspaces(q, account, workspace))
    end
  end

  # P7 (§4.2): thresholds resolve `min(account, workspace)`, so the rendered
  # reason has to be computed against the same pair the gate itself uses —
  # otherwise `arb quota` reports headroom that dispatch has already closed.
  defp gating_for(q, account, workspace) do
    policy = {account, workspace}

    case Arbiter.Quota.Gate.gating_window(q, policy) do
      nil ->
        %{gating_window: nil, gating_reason: nil}

      %{window: w} ->
        %{gating_window: w, gating_reason: Arbiter.Quota.Gate.hold_phrase(q, policy)}
    end
  end

  # bd-aw325c: the headline reads ONE workspace's ceiling (the account's
  # alphabetically-first, or `--workspace`), but dispatch reads the task's own.
  # Any other workspace on the account whose `min(account, workspace)` ceiling
  # is already crossed is listed, so "gating dispatch: none" can't hide a
  # workspace that is being held.
  defp gating_workspaces(_q, nil, _workspace), do: []

  defp gating_workspaces(q, account, shown) do
    account.id
    |> Resolver.workspaces()
    |> Enum.reject(&((shown && &1.id == shown.id) || Arbiter.Quota.continue_mode?(&1)))
    |> Enum.map(&{&1, gating_for(q, account, &1)})
    |> Enum.reject(fn {_ws, gating} -> gating.gating_window == nil end)
    |> Enum.map(fn {ws, gating} ->
      %{
        workspace_id: ws.id,
        workspace: ws.name,
        window: gating.gating_window,
        reason: gating.gating_reason
      }
    end)
  end

  defp account_pause(%Arbiter.Accounts.ProviderAccount{} = account),
    do: Arbiter.Providers.Pause.for_account(account)

  defp account_pause(_), do: nil

  defp safe_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- account identity + per-workspace breakdown (P5, §6) ---------------

  @doc """
  The account header §6's `arb quota` prints, plus the per-workspace spend
  breakdown underneath it: `%{account: …, workspaces: […]}`.

  `workspaces` carries each workspace metered under the account with its own
  30-day spend for `provider`, so the CLI can render
  `default $A · emricare $B · vstim $C` under the account total. Empty when
  the account has no workspaces linked to it yet.

  `cache` is an optional `spend_cache/1` memo. Each `workspace_spend/1` term
  is a full 30-day ledger scan for that workspace and is *provider
  independent*, so a caller that asks for several providers' fields (every
  page mount goes through `list_latest/2`, which asks for four) must pass one
  cache rather than rescan the ledger once per provider per workspace.
  """
  @spec account_fields(String.t() | nil, String.t(), spend_cache()) :: map()
  def account_fields(account_id, provider \\ @default_provider, cache \\ %{}) do
    %{
      account: account_view(Resolver.get(account_id)),
      workspaces:
        Enum.map(Resolver.workspaces(account_id), fn ws ->
          %{id: ws.id, name: ws.name, cost_usd: cost_for(provider, cached_spend(ws.id, cache))}
        end)
    }
  end

  defp cached_spend(workspace_id, cache),
    do: Map.get_lazy(cache, workspace_id, fn -> workspace_spend(workspace_id) end)

  defp account_view(%ProviderAccount{} = account) do
    %{
      id: account.id,
      slug: account.slug,
      provider: Atom.to_string(account.provider),
      label: account.label,
      plan: account.plan
    }
  end

  defp account_view(_), do: nil

  # ---- uniform multi-provider view (bd-ajh7bd) ---------------------------

  @doc """
  The canonical empty quota "view" — the uniform two-window shape the topbar and
  `/usage` page render, one entry per tracked provider. Each provider's `view/1`
  merges its real figures onto this so the UI can read a single set of keys
  (`utilization_5h`, `reset_5h_at`, `overage_status`, …) across Claude, Codex
  and Antigravity — whose native shapes differ (5h/7d vs session/weekly vs
  per-group buckets). `primary_label` / `secondary_label` name the two bars per
  provider (Claude: "5h"/"7d"; Codex: "session"/"weekly"; Antigravity:
  "5h"/"weekly", or "used"/none when its snapshot has no parseable buckets).
  """
  @spec blank_view(String.t()) :: map()
  def blank_view(provider) when is_binary(provider) do
    %{
      # Deprecated (P5): kept for one release as the alias for "the workspace
      # this view was looked up through". The account is the real key.
      workspace_id: nil,
      provider_account_id: nil,
      account: nil,
      workspaces: [],
      provider: provider,
      utilization_5h: nil,
      reset_5h_at: nil,
      status_5h: nil,
      utilization_7d: nil,
      reset_7d_at: nil,
      status_7d: nil,
      overage_status: nil,
      representative_claim: nil,
      captured_at: nil,
      per_model_utilization: %{},
      extra_usage: %{},
      oauth_utilization_5h: nil,
      oauth_utilization_7d: nil,
      oauth_captured_at: nil,
      capture_source: nil,
      primary_label: "5h",
      secondary_label: "7d",
      plan: nil,
      message: nil,
      models: [],
      cost_usd: nil
    }
  end

  @doc "Map a loaded `AnthropicQuota` row to the uniform quota view shape."
  @spec view(AnthropicQuota.t()) :: map()
  def view(%AnthropicQuota{} = q) do
    blank_view(q.provider)
    |> Map.merge(%{
      provider_account_id: q.provider_account_id,
      utilization_5h: q.utilization_5h,
      reset_5h_at: q.reset_5h_at,
      status_5h: q.status_5h,
      utilization_7d: q.utilization_7d,
      reset_7d_at: q.reset_7d_at,
      status_7d: q.status_7d,
      overage_status: q.overage_status,
      representative_claim: q.representative_claim,
      captured_at: q.captured_at,
      per_model_utilization: q.per_model_utilization || %{},
      extra_usage: q.extra_usage || %{},
      oauth_utilization_5h: q.oauth_utilization_5h,
      oauth_utilization_7d: q.oauth_utilization_7d,
      oauth_captured_at: q.oauth_captured_at,
      capture_source: q.capture_source
    })
  end

  @doc """
  The human-readable `codex_message` the `arb quota` / `quota_get` surface pairs
  with a `nil` Codex snapshot. `nil` when a snapshot *is* present (bd-ajh7bd).

  In the pure-DB-read world a missing Codex row means the periodic probe hasn't
  stored one yet — almost always because the `codex` CLI isn't authenticated on
  this host (the probe no-ops without creds).
  """
  @spec codex_absence_message(map() | nil) :: String.t() | nil
  def codex_absence_message(nil),
    do: "Codex quota not captured yet — authenticate the codex CLI on this host."

  def codex_absence_message(_present), do: nil

  @doc "Serialize a loaded `AnthropicQuota` row into the public map shape."
  @spec serialize_quota(AnthropicQuota.t()) :: map()
  def serialize_quota(%AnthropicQuota{} = q) do
    %{
      provider: q.provider,
      provider_account_id: q.provider_account_id,
      utilization_5h: q.utilization_5h,
      reset_5h_at: iso(q.reset_5h_at),
      status_5h: q.status_5h,
      utilization_7d: q.utilization_7d,
      reset_7d_at: iso(q.reset_7d_at),
      status_7d: q.status_7d,
      representative_claim: q.representative_claim,
      overage_status: q.overage_status,
      captured_at: iso(q.captured_at),
      # bd-2wnkoq: how old the snapshot is, computed here so `arb quota` reads
      # the same whatever the CLI host's clock says. nil before any capture.
      captured_age_seconds: age_seconds(q.captured_at),
      stale: Arbiter.Quota.Gate.stale?(q),
      # bd-4fbpto: `stale` alone can't distinguish "nothing has succeeded in a
      # while" from "the poll is fine, it just hasn't landed a usable 5h figure
      # this cycle" — both look identical (STALE, old `captured_at`) without
      # this. `arb quota` uses it to say which one it is.
      oauth_poll_fresh: Arbiter.Quota.Gate.oauth_poll_fresh?(q),
      # bd-1pmf9h: `stale` alone reads identically whether the poll is merely
      # quiet or the fleet is flatly unauthenticated — a dead token still
      # serves a stale-but-present snapshot for hours. Surfaces
      # `CredentialWatchdog`'s own expiry state (set by `CloudProbe`'s
      # consecutive-401 tracking or the periodic CLI probe) directly here.
      credentials_expired: Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Claude),
      per_model_utilization: q.per_model_utilization || %{},
      extra_usage: q.extra_usage || %{},
      oauth_utilization_5h: q.oauth_utilization_5h,
      oauth_utilization_7d: q.oauth_utilization_7d,
      oauth_captured_at: iso(q.oauth_captured_at),
      capture_source: q.capture_source
    }
  end

  # ---- Google Cloud Code Assist quota (bd-57ukgb) ------------------------

  @doc """
  On-demand Antigravity quota snapshot via the `agy` CLI
  (`Arbiter.Quota.CloudCode`). The upstream Gemini CLI snapshot is gone with
  its provider (bd-ac53wz).

  Returns `%{antigravity: snapshot | nil}`. Unlike the Anthropic snapshot —
  persisted from OAuth polling + response header capture — this fetches live,
  bounded by a timeout; a hung or crashed fetch degrades to `nil`.

  Gated by the `:arbiter, :cloud_code_quota` `:enabled` flag (default on; the
  test env turns it off so `GET /api/quota` stays a pure DB read there). Pass
  `enabled: true` in `opts` to force the live path in a test that stubs HTTP.

  Options are forwarded to `CloudCode.antigravity/1`.
  """
  @spec google_snapshots(keyword()) :: %{antigravity: map() | nil}
  def google_snapshots(opts \\ []) do
    if google_enabled?(opts) do
      fetch_opts = Keyword.delete(opts, :enabled)
      antigravity = Task.async(fn -> CloudCode.antigravity(fetch_opts) end)

      %{antigravity: await_snapshot(antigravity)}
    else
      %{antigravity: nil}
    end
  end

  defp google_enabled?(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, val} -> val == true
      :error -> Application.get_env(:arbiter, :cloud_code_quota, [])[:enabled] != false
    end
  end

  # CloudCode fetchers never raise, but bound the wall time anyway so a stalled
  # Google endpoint can't hang the quota surface. A timeout / crash → nil.
  # 24s, not 20s: `shell_out_agy_usage/2`'s own `Task.yield` allows the agy
  # subprocess up to `@default_agy_usage_timeout_ms` (20s) plus the `timeout
  # -k 1` SIGKILL grace plus its own 3s margin (~23s total, `cloud_code.ex`)
  # before it gives up and reads back a killed-but-finished run — brutal-
  # killing it here first would throw that recovery away.
  defp await_snapshot(task) do
    case Task.yield(task, 24_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  @doc """
  On-demand fetch of Anthropic's `/api/oauth/usage` endpoint (bd-8tpha6) —
  per-model weekly utilization + `extra_usage` overage, layered onto the
  account's `AnthropicQuota` snapshot alongside (never instead of) the
  header-capture aggregate figures. Takes a `provider_account_id` since P5
  (§6) — `/api/oauth/usage` is an account endpoint and always was.

  Best-effort by design: a 429 cooldown (`Arbiter.Quota.OAuthUsage`), missing
  credentials, or any transport error is returned as `{:error, reason}` here
  but never raises — callers that just want "whatever we have" should use
  `refresh_and_serialize/2` instead, which swallows this outright.

  Since P6 (§9), an explicit `:token` in `opts` (tests, or an already-resolved
  credential) is always honored as-is. Otherwise this resolves *this
  account's own* `cli_credentials_file` credential
  (`Arbiter.Accounts.Credentials.account_oauth_usage_token/1`) to authenticate
  the request, and tags the fetch with `:provider_account_id` so
  `Arbiter.Quota.OAuthUsage`'s 429 cooldown is keyed on the account, not
  whichever credential happened to authenticate it — two credentials on one
  account (e.g. mid-rotation) share the one cooldown window the account's
  rate limit actually enforces. An account with no credential row yet (a
  pre-migration install, or one whose only credential is the `:oauth_token`
  setup token, which this endpoint rejects — bd-4ag0nj) falls back to
  `OAuthUsage.fetch/1`'s own default (the operator's `.credentials.json` on
  disk). When workers run on their own token (the account's `:oauth_token`
  row), a `:no_credentials` or
  `{:http_error, 401}` from that fallback is returned as
  `{:operator_login_lapsed, reason}`: the operator's interactive login
  lapsed, not a credential workers use. Otherwise workers are seeded that
  same file, so the bare reason is kept.

  An account's dedicated quota grant (a `:cli_credentials_path` credential,
  bd-b632tz — `Arbiter.Accounts.Credentials.account_quota_grant_path/1`)
  outranks all of the above: its `.credentials.json` is re-read for the
  access token on every call (`Arbiter.Quota.GrantFile`) and never
  persisted. A 401 with it, or a grant file that is missing or logged out
  (`{:grant_unreadable, reason}`), is returned as `{:quota_grant_lapsed,
  path, reason}` — no fallback to another credential — so `CloudProbe` can
  page with the re-login command for that config dir.
  """
  @spec capture_oauth_usage(String.t() | nil, keyword()) ::
          {:ok, AnthropicQuota.t()} | {:error, term()}
  def capture_oauth_usage(account_id, opts \\ []) do
    case capture_oauth_usage_tagged(account_id, opts) do
      {:error, {_stage, reason}} -> {:error, reason}
      other -> other
    end
  end

  # Same fetch-then-write as `capture_oauth_usage/2`, but keeps the failure
  # tagged with which stage produced it (`:fetch` vs `:write`) instead of
  # collapsing both to a bare `{:error, reason}`. `write_once_per_account/4`
  # needs that distinction: a per-account *fetch* failure (a 401, a transport
  # error, an unresolvable account) must count toward `CloudProbe`'s
  # consecutive-failure/401 streaks even when other accounts in the same
  # cycle succeed, while a *write* failure (fetch succeeded, only the DB
  # write failed) must not be conflated with it. See the HIGH finding on
  # bd-3j92yv: before this, both stages surfaced as the same bare error and
  # `CloudProbe.note_oauth_result/3` reset the streak on any cycle where at
  # least one account succeeded, silently killing 401/failure detection for
  # any multi-account install.
  defp capture_oauth_usage_tagged(account_id, opts) do
    provider = Keyword.get(opts, :provider, @default_provider)

    case fetch_account_id(account_id) do
      {:error, reason} ->
        {:error, {:fetch, reason}}

      {:ok, id} ->
        {fetch_opts, token_source} = account_oauth_fetch_opts(id, opts)

        case fetch_oauth_usage(fetch_opts, token_source) do
          {:error, reason} -> {:error, {:fetch, label_fetch_error(id, token_source, reason)}}
          {:ok, usage} -> tag_write_error(record_oauth_usage(id, provider, usage))
        end
    end
  end

  # bd-4ag0nj: when the fetch fell back to the operator's interactive
  # `~/.claude/.credentials.json` (the account has no `cli_credentials_file`
  # row — on the live install its only credential is the `:oauth_token`
  # setup token workers run on, which `/api/oauth/usage` answers with a 429
  # and `Retry-After: 3600`), a missing file or a 401 means that interactive
  # login lapsed: its ~8h access token only refreshes while an interactive
  # `claude` session runs. Tag it so `CloudProbe` can page with that cause,
  # instead of a generic poll failure or an account/worker credential expiry.
  #
  # Only when workers demonstrably don't use that file, though: with no worker
  # token anywhere, `Arbiter.Agents.Claude.ConfigDir` seeds workers a copy of
  # this same `.credentials.json`, so its 401 is a real worker-credential
  # expiry and keeps the bare reason `CloudProbe`'s 401 streak keys on.
  defp label_fetch_error(account_id, :operator_credentials_file, reason)
       when reason == :no_credentials or reason == {:http_error, 401} do
    if workers_on_own_token?(account_id),
      do: {:operator_login_lapsed, reason},
      else: reason
  end

  # bd-b632tz: the account's dedicated quota grant is used by nothing but
  # this poll — workers never see it — so its 401 (or a grant file that is
  # gone or logged out) is never a worker-credential expiry. Tag it with the
  # grant's path so `CloudProbe` pages with the re-login command for exactly
  # that config dir instead of feeding the Claude 401 streak.
  defp label_fetch_error(_account_id, {:quota_grant, path}, reason)
       when reason == {:http_error, 401} or
              (is_tuple(reason) and elem(reason, 0) == :grant_unreadable),
       do: {:quota_grant_lapsed, path, reason}

  defp label_fetch_error(_account_id, _token_source, reason), do: reason

  # The grant's access token is read from its file here, at fetch time, on
  # every poll — never cached or persisted — so a refresh the CLI writes in
  # place is picked up by the very next poll.
  defp fetch_oauth_usage(fetch_opts, {:quota_grant, path}) do
    case GrantFile.read(path) do
      {:ok, grant} -> OAuthUsage.fetch(Keyword.put(fetch_opts, :token, grant.access_token))
      {:error, reason} -> {:error, {:grant_unreadable, reason}}
    end
  end

  defp fetch_oauth_usage(fetch_opts, _token_source), do: OAuthUsage.fetch(fetch_opts)

  # A workspace's workers read only their own account's credential
  # (`ConfigDir.oauth_token/1`, the only source since the P13 flip) — so this
  # account's `:oauth_token` row is the answer, and another account's token,
  # or one left in the server environment, must not vouch for it.
  defp workers_on_own_token?(account_id), do: Credentials.worker_oauth_token?(account_id)

  defp tag_write_error({:error, reason}), do: {:error, {:write, reason}}
  defp tag_write_error(ok), do: ok

  # Resolves the token to authenticate `/api/oauth/usage` with (see the
  # moduledoc on `capture_oauth_usage/2`). An explicit `:token` already in
  # `opts` — the pre-P6 shape every existing test and on-demand caller uses —
  # is never overridden, and in that case the cooldown stays keyed on the
  # token exactly as before P6, so a caller that already knows exactly which
  # credential it wants keeps full control of both the fetch and the
  # cooldown it shares with other calls using that same explicit token.
  #
  # Also returns where the token comes from — `:explicit`, `{:quota_grant,
  # path}`, `:account`, or `:operator_credentials_file` (the
  # `OAuthUsage.fetch/1` on-disk default) — so a failure can be attributed to
  # the credential that actually failed.
  #
  # The account's dedicated quota grant (`:cli_credentials_path`, bd-b632tz)
  # outranks every stored credential: it is the one source that stays valid
  # with no interactive session, because `Arbiter.Quota.GrantRefresher` has
  # the CLI renew it. It never falls back — a lapsed grant must page with its
  # own fix rather than quietly polling on a snapshot or the operator's login.
  defp account_oauth_fetch_opts(account_id, opts) do
    if Keyword.has_key?(opts, :token) do
      {opts, :explicit}
    else
      case Credentials.account_quota_grant_path(account_id) do
        {:ok, path} ->
          {Keyword.put(opts, :provider_account_id, account_id), {:quota_grant, path}}

        :none ->
          stored_credential_fetch_opts(account_id, opts)
      end
    end
  end

  defp stored_credential_fetch_opts(account_id, opts) do
    case Credentials.account_oauth_usage_token(account_id) do
      # Only tag the fetch with `:provider_account_id` — and so only key
      # its 429 cooldown on the account — when a per-account credential
      # was actually resolved. When it wasn't (`:none`: pre-migration or
      # partially-migrated install), `OAuthUsage.fetch/1` falls back to
      # the operator's on-disk `.credentials.json`, the same real token
      # every credential-less account shares; tagging the account here
      # regardless (as before) gave every such account its own cooldown
      # key for that one shared token, so a 429 on one no longer
      # suppressed the others — exactly the multiplication this option
      # exists to eliminate. Leaving `opts` untouched here keeps the
      # pre-P6 token-keyed cooldown for that shared-fallback case.
      {:ok, token} ->
        opts =
          opts
          |> Keyword.put(:provider_account_id, account_id)
          |> Keyword.put(:token, token)

        {opts, :account}

      :none ->
        {opts, :operator_credentials_file}
    end
  end

  # A write has to name a real account row: the quota tables carry no FK (the
  # column is plain text on SQLite), so a caller that still passes a
  # workspace id here would otherwise create a row keyed by something that is
  # not an account and never be read back. Fail loudly instead.
  defp fetch_account_id(account_id) when is_binary(account_id) and account_id != "" do
    case Resolver.get(account_id) do
      %ProviderAccount{id: id} -> {:ok, id}
      _ -> {:error, {:no_provider_account, account_id}}
    end
  end

  defp fetch_account_id(other), do: {:error, {:no_provider_account, other}}

  @doc """
  `capture_oauth_usage/2`, but for a *group of workspaces* (bd-5xuneh).
  `/api/oauth/usage` is account-wide and rate-limited per account, not per
  workspace, so fetching it once per workspace burns the shared rate-limit
  budget for an identical number.

  bd-5xuneh originally grouped workspaces by
  `Arbiter.Agents.Claude.ConfigDir.oauth_token/1` and passed the resolved
  token through `opts`, on the theory that a workspace's own `worker_env`
  token could authenticate this call. bd-4fbpto found that backwards — that
  token is scope/rate-limited for this endpoint and passing it here is why
  every poll silently failed once the header-capture fallback was removed
  (see the status codes and body shapes recorded in PR #1607).

  Each workspace id is resolved to the account it meters under (§6), and this
  fetches **once per distinct account**, not once for the whole group — P5
  made the *write* per-account; P6 (§9) is what makes the *fetch* genuinely
  per-account too, via `capture_oauth_usage/2`, so N accounts sharing this
  cycle's workspace list get N independent fetches, each authenticated with
  that account's own credential (or the install-wide default, when the
  account has none — see `capture_oauth_usage/2`). Three workspaces on one
  account still produce exactly one fetch and one write, exactly as before.

  Returns `{:ok, results}` with one entry per input workspace, in the same
  order, so a caller can tell which workspace's account failed — workspaces
  sharing an account share that account's result. Each failure is tagged
  with the stage it came from, `{:error, {:fetch, reason}}` (the account's
  own `/api/oauth/usage` fetch failed — a 401, a transport error, an
  unresolvable workspace/account) or `{:error, {:write, reason}}` (the fetch
  succeeded, only the DB write failed), so a caller like `CloudProbe` can
  tell "this account's credential/upstream is broken" apart from "the fetch
  was fine, persistence hiccuped" instead of conflating the two (bd-3j92yv).
  When every workspace in the group resolves to the *same* failure
  (typically: one account, or every account failing identically), the
  failure is surfaced as a bare, still-tagged `{:error, {stage, reason}}`
  instead of the `{:ok, results}` wrapper, matching this function's pre-P6
  contract shape (minus the tag) for the single-account case every existing
  caller relies on.
  """
  @spec capture_oauth_usage_for_group([String.t()], keyword()) ::
          {:ok, [{:ok, AnthropicQuota.t()} | {:error, {:fetch | :write, term()}}]}
          | {:error, {:fetch | :write, term()}}
  def capture_oauth_usage_for_group(workspace_ids, opts \\ []) when is_list(workspace_ids) do
    provider = Keyword.get(opts, :provider, @default_provider)

    {results, _seen} =
      Enum.map_reduce(workspace_ids, %{}, fn workspace_id, seen ->
        write_once_per_account(workspace_id, provider, opts, seen)
      end)

    collapse_uniform_failure(results)
  end

  # One fetch + write per distinct account per cycle. `seen` memoizes the
  # result so the second and third workspace on an account neither re-fetch
  # nor re-write, and report the same outcome as the first.
  defp write_once_per_account(workspace_id, provider, opts, seen) do
    with {:ok, ws_id} <- resolve_workspace_id(workspace_id),
         {:ok, account_id} <- ensure_account_id(ws_id, provider) do
      case Map.fetch(seen, account_id) do
        {:ok, result} ->
          {result, seen}

        :error ->
          result = capture_oauth_usage_tagged(account_id, Keyword.put(opts, :provider, provider))
          {result, Map.put(seen, account_id, result)}
      end
    else
      {:error, reason} -> {{:error, {:fetch, reason}}, seen}
    end
  end

  # Pre-P6 callers (and every existing test) expect a single fetch shared by
  # the whole group to fail as a bare `{:error, reason}`, not
  # `{:ok, [{:error, reason}, ...]}` — this keeps that contract for the
  # common case (one account, or every account failing the same way) while
  # still exposing real per-account divergence (some accounts ok, some not)
  # through the per-workspace `results` list.
  defp collapse_uniform_failure(results) do
    results
    |> Enum.map(fn
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end)
    |> Enum.uniq()
    |> case do
      [{:error, reason}] -> {:error, reason}
      _ -> {:ok, results}
    end
  end

  # Persist one parsed `/api/oauth/usage` snapshot (bd-b0zody).
  #
  # The poll is the *primary* quota source: when the body carried an aggregate
  # 5h figure we write the primary columns (`utilization_5h` / `status_5h` /
  # `reset_5h_at` / the 7d trio / `representative_claim` / `overage_status`)
  # plus a fresh `captured_at`, so `Arbiter.Quota.Gate` gates off the poll
  # rather than depending on worker traffic alone.
  #
  # Two guards keep a thin or broken body from erasing a good row:
  #
  #   * no aggregate 5h figure → fall back to the narrow secondary-only write,
  #     which touches neither the primary columns nor `captured_at`;
  #   * any individual `nil` field is dropped from the attrs, so the upsert
  #     never nils out a column another source had filled in (`AshSqlite`
  #     narrows `upsert_fields` to the attributes actually on the changeset).
  #
  # A fetch that failed outright (429 / cooldown / transport) never reaches
  # here at all, so the previous row survives untouched.
  defp record_oauth_usage(account_id, provider, usage) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    secondary = %{
      provider_account_id: account_id,
      provider: provider,
      per_model_utilization: usage.per_model_utilization,
      extra_usage: usage.extra_usage,
      oauth_utilization_5h: usage.utilization_5h,
      oauth_utilization_7d: usage.utilization_7d,
      oauth_captured_at: now
    }

    {action, attrs} =
      if is_number(usage.utilization_5h) do
        primary =
          %{
            utilization_5h: usage.utilization_5h,
            status_5h: usage.status_5h,
            reset_5h_at: usage.reset_5h_at,
            utilization_7d: usage.utilization_7d,
            status_7d: usage.status_7d,
            reset_7d_at: usage.reset_7d_at,
            representative_claim: usage.representative_claim,
            overage_status: usage.overage_status
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
          |> Map.merge(%{captured_at: now, capture_source: @oauth_poll_source})

        {:record_oauth_snapshot, Map.merge(secondary, primary)}
      else
        {:record_oauth_usage, secondary}
      end

    result =
      AnthropicQuota
      |> Ash.Changeset.for_create(action, attrs)
      |> Ash.create()

    with {:ok, quota} <- result do
      # Only a poll that carried the aggregate figures is a history sample; the
      # secondary-only write touched no primary column.
      if action == :record_oauth_snapshot, do: Arbiter.Quota.History.record(account_id, quota)
      broadcast_quota_update(account_id, quota)
    end

    result
  end

  @doc """
  `serialize/2`, but first attempts a `capture_oauth_usage/2` refresh and
  silently ignores any failure (missing creds, 429 cooldown, network error) —
  the header-capture aggregate figures already in the snapshot are returned
  either way. This is what `arb quota` / the `quota_get` MCP tool call.
  """
  @spec refresh_and_serialize(String.t() | nil, String.t(), keyword()) :: map() | nil
  def refresh_and_serialize(account_id, provider \\ @default_provider, opts \\ []) do
    _ = safe_capture_oauth_usage(account_id, provider: provider)
    serialize(account_id, provider, opts)
  end

  defp safe_capture_oauth_usage(account_id, opts) do
    capture_oauth_usage(account_id, opts)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  @doc """
  Every tracked provider's latest quota snapshot for the given provider
  account(s), as the uniform view map (`view/1` / `Codex.view/1` / `CloudCode.view/1`) — one entry
  per distinct `provider`, `"claude"` sorted first (so the single-provider case
  renders exactly as before), the rest alphabetically.

  Merges three sources (bd-ajh7bd): the generic `AnthropicQuota` table (Claude +
  any legacy header-capture provider), the dedicated `CodexQuota` table, and the
  dedicated `GoogleQuota` table (Antigravity). When the same
  provider appears in both a dedicated table and the generic one, the dedicated
  row wins. This is the single read path the topbar, `/usage` LiveView, and the
  REST `quotas` list all sit on — no live provider fetch at request time.

  Each view also carries `cost_usd` — the provider's actual spend over the last
  #{@cost_window_days} days from the `Arbiter.Usage` ledger (`nil` when none) —
  so the dashboard can show dollars alongside utilization.

  `:spend_cache` reuses a caller's `spend_cache/1` memo (e.g. `GET /api/quota`,
  which also serializes Claude on its own); with none given this reads
  `Arbiter.Quota.SpendCache`'s memoized `Arbiter.Usage.spend_by_workspace/1`
  aggregate, so no request pays for a ledger scan of its own (bd-4p6pw7).

  `:exclude_providers` (default `[]`) drops a view whose provider is in the
  list before decoration — so a caller that never wants a given provider
  (`Arbiter.Quota.Visibility`, for the providers it doesn't show) doesn't pay
  even the memoized cache lookup for it. `GET /api/quota` and `arb quota`
  pass none, and keep showing every provider.
  """
  @spec list_latest(String.t() | [String.t()] | map(), keyword()) :: [map()]
  def list_latest(accounts, opts \\ []) do
    account_ids = normalize_account_ids(accounts)
    excluded = Keyword.get(opts, :exclude_providers, [])

    if account_ids == [] do
      []
    else
      dedicated = codex_views(account_ids) ++ google_views(account_ids)
      dedicated_providers = MapSet.new(dedicated, & &1.provider)

      generic =
        AnthropicQuota
        |> Ash.Query.filter(provider_account_id in ^account_ids)
        |> Ash.read!()
        |> Enum.map(&view/1)
        |> Enum.reject(&MapSet.member?(dedicated_providers, &1.provider))

      case (generic ++ dedicated) |> Enum.reject(&(&1.provider in excluded)) do
        # No captured quota anywhere on these accounts — nothing to decorate,
        # so don't pay for the ledger scans a cache would run up front.
        [] ->
          []

        views ->
          cache = Keyword.get_lazy(opts, :spend_cache, fn -> spend_cache(account_ids) end)

          views
          |> Enum.map(&decorate_view(&1, cache))
          |> Enum.sort_by(&{&1.provider != @default_provider, &1.provider})
      end
    end
  rescue
    _ -> []
  end

  @doc """
  `list_latest/2` for a caller that holds a workspace: resolves every
  provider account the workspace is linked to, then reads by account. The
  shape the dashboard and `GET /api/quota` still speak.

  Each view also carries `gate_policy` — `gate_policy/2` for its account and
  this workspace — so the quota bars can colour by the gate's own thresholds
  (bd-clzkvp). It holds structs, so `serialize_view/1` leaves it out.

  A caller that already holds the `Workspace` row passes it as `workspace:`
  and the policy is built from it instead of a second read of `workspaces`.
  """
  @spec list_latest_for_workspace(String.t() | nil, keyword()) :: [map()]
  def list_latest_for_workspace(workspace_id, opts \\ []) do
    workspace =
      Keyword.get_lazy(opts, :workspace, fn -> workspace_id && safe_workspace(workspace_id) end)

    views =
      case workspace_id |> account_ids() |> list_latest(opts) do
        [] ->
          []

        views ->
          Enum.map(views, fn view ->
            view
            |> Map.put(:workspace_id, workspace_id)
            |> Map.put(:gate_policy, gate_policy(view.provider_account_id, workspace))
          end)
      end

    views ++ grok_views(workspace_id, workspace)
  end

  @doc """
  grok's entry in a workspace's quota list (bd-co08p2), present only while the
  workspace has `routing.grok.enabled` (`Arbiter.Agents.GrokRouting`). It is
  the `Arbiter.Quota.GrokLedger` estimate, not a polled number: the view
  carries an `:estimate` map (`%{window: "24h", used_tokens:, cap_tokens:}`)
  and no `message`, so it never reads as stale. The window is rolling, so
  `reset_5h_at` is when enough usage has aged out to fall under the gate, not
  a fixed reset. `[]` when grok routing is off or the ledger cannot be read.
  """
  @spec grok_views(String.t() | nil, Workspace.t() | nil) :: [map()]
  def grok_views(workspace_id, %Workspace{} = workspace) do
    with true <- Arbiter.Agents.GrokRouting.enabled?(workspace),
         %Snapshot{} = snap <- Arbiter.Quota.GrokLedger.snapshot() do
      cap = Arbiter.Quota.GrokLedger.cap()

      [
        "grok"
        |> blank_view()
        |> Map.merge(%{
          workspace_id: workspace_id,
          gate_policy: gate_policy(nil, workspace),
          utilization_5h: snap.utilization,
          reset_5h_at: snap.reset_at,
          captured_at: snap.captured_at,
          primary_label: snap.window_label,
          secondary_label: nil,
          plan: "free",
          capture_source: "ledger_estimate",
          estimate: %{
            window: snap.window_label,
            used_tokens: round(snap.utilization * cap),
            cap_tokens: cap
          }
        })
      ]
    else
      _ -> []
    end
  end

  def grok_views(_workspace_id, _workspace), do: []

  @doc """
  The policy `Arbiter.Quota.Gate` resolves for dispatch on `account_id` from
  `workspace` (bd-clzkvp): `policy` is the `{account, workspace}` pair the
  gate's thresholds compose over, and `enforcing?` is `false` when the
  workspace's gate is `:continue` — it dispatches past the cap, so no
  threshold ever holds it.
  """
  @spec gate_policy(String.t() | nil, Workspace.t() | nil) :: %{
          policy: {ProviderAccount.t() | nil, Workspace.t() | nil},
          enforcing?: boolean()
        }
  def gate_policy(account_id, workspace) do
    %{policy: {Resolver.get(account_id), workspace}, enforcing?: not continue_mode?(workspace)}
  end

  defp normalize_account_ids(accounts) when is_map(accounts) and not is_struct(accounts),
    do: accounts |> Map.values() |> normalize_account_ids()

  defp normalize_account_ids(accounts) when is_list(accounts),
    do: accounts |> Enum.filter(&is_binary/1) |> Enum.uniq()

  defp normalize_account_ids(account_id) when is_binary(account_id), do: [account_id]
  defp normalize_account_ids(_), do: []

  # Each view carries its *own* account's spend and workspace breakdown — two
  # accounts in one list are two separate budgets and must not be summed.
  #
  # The headline `cost_usd` is `provider_spend/1` read straight off the
  # account's `usage_events`, NOT a sum of the per-workspace breakdown below:
  # `account_fields/3`'s `workspaces` list is built from `workspace_spend/1`,
  # which only sums rows carrying a `workspace_id`, so a probe/pre-flight row
  # (`workspace_id: nil`, always a `provider_account_id`) would silently drop
  # out of a summed total — the exact under-reporting bias bd-adyhvn measured.
  # The total can therefore be *larger* than the sum of the breakdown lines
  # printed under it; that gap is exactly the account's workspace-less spend.
  defp decorate_view(view, cache) do
    fields = account_fields(view.provider_account_id, view.provider, cache)
    total = cost_for(view.provider, provider_spend(view.provider_account_id))

    view
    |> Map.merge(fields)
    |> Map.put(:cost_usd, total)
  end

  @doc """
  Per-provider actual spend for the **account** over the last
  #{@cost_window_days} days, as a `%{ledger_provider => total_cost_usd}` map
  drawn from the `Arbiter.Usage` ledger. Keyed by the *ledger* provider
  ("claude" / "gemini" / "openai"); `cost_for/2` maps quota codes onto it.
  Returns `%{}` on any error so cost is a best-effort add-on, never a failure.

  "How much of this plan did I spend?" is an account question (§8), read
  straight off `usage_events.provider_account_id` (P9) rather than summed
  through the workspace link — `workspace_spend/1` sums *only* rows that
  carry a `workspace_id`, so a probe/pre-flight row (`workspace_id: nil`, but
  always a `provider_account_id` — §8's seam with bd-adyhvn) would silently
  drop out of the total, reintroducing the exact under-reporting bias
  bd-adyhvn measured. `workspace_spend/1` is still the per-workspace term
  §6's breakdown line prints, since that one *is* workspace-scoped by
  definition.
  """
  @spec provider_spend(String.t() | nil) :: %{optional(String.t()) => float()}
  def provider_spend(nil), do: %{}

  def provider_spend(account_id) when is_binary(account_id) do
    SpendCache.account_totals() |> Map.get(account_id, %{})
  rescue
    _ -> %{}
  end

  def provider_spend(_), do: %{}

  @doc """
  Build the `t:spend_cache/0` memo for `accounts`: `workspace_spend/1` for
  every distinct workspace metered under them, read off the one memoized
  `Arbiter.Quota.SpendCache.workspace_totals/0` aggregate (bd-4p6pw7) rather
  than a scan per workspace.

  `list_latest/2` builds one of these per pass; a caller that makes several
  calls for one request (`GET /api/quota`) builds it once and passes it to
  each.
  """
  @spec spend_cache(String.t() | [String.t()] | map()) :: spend_cache()
  def spend_cache(accounts) do
    accounts
    |> normalize_account_ids()
    |> Enum.flat_map(&Resolver.workspace_ids/1)
    |> Enum.uniq()
    |> Map.new(&{&1, workspace_spend(&1)})
  end

  @doc """
  One workspace's own per-provider spend over the last #{@cost_window_days}
  days — the breakdown term under §6's account total.
  """
  @spec workspace_spend(String.t() | nil) :: %{optional(String.t()) => float()}
  def workspace_spend(workspace_id) when is_binary(workspace_id) do
    SpendCache.workspace_totals() |> Map.get(workspace_id, %{})
  rescue
    _ -> %{}
  end

  def workspace_spend(_), do: %{}

  # Roll the ledger spend for a quota provider code up from its mapped ledger
  # key(s). `nil` (not `0.0`) when the provider has no spend / no clean mapping,
  # so the UI shows "—" rather than a misleading "$0.00".
  defp cost_for(provider, spend) do
    keys = Map.get(@ledger_providers, provider, [])

    case Enum.reduce(keys, {0.0, false}, fn key, {sum, any?} ->
           case Map.get(spend, key) do
             c when is_number(c) -> {sum + c, true}
             _ -> {sum, any?}
           end
         end) do
      {_sum, false} -> nil
      {sum, true} -> Float.round(sum, 6)
    end
  end

  defp codex_views(account_ids) do
    for account_id <- account_ids,
        row = Arbiter.Quota.Codex.latest(account_id),
        not is_nil(row) do
      Arbiter.Quota.Codex.view(row)
    end
  rescue
    _ -> []
  end

  defp google_views(account_ids) do
    for account_id <- account_ids,
        row = CloudCode.latest(account_id, "antigravity"),
        not is_nil(row) do
      CloudCode.view(row)
    end
  rescue
    _ -> []
  end

  @doc "`list_latest/2`, serialized into the public map shape (ISO timestamps)."
  @spec list_serialized(String.t() | [String.t()] | map(), keyword()) :: [map()]
  def list_serialized(accounts, opts \\ []) do
    accounts
    |> list_latest(opts)
    |> Enum.map(&serialize_view/1)
  end

  @doc "`list_latest_for_workspace/2`, serialized into the public map shape."
  @spec list_serialized_for_workspace(String.t() | nil, keyword()) :: [map()]
  def list_serialized_for_workspace(workspace_id, opts \\ []) do
    workspace_id
    |> list_latest_for_workspace(opts)
    |> Enum.map(&serialize_view/1)
  end

  @doc """
  Serialize a uniform view map (from `list_latest/1`) into the public,
  string-friendly shape — ISO-8601 timestamps, JSON-safe values.
  """
  @spec serialize_view(map()) :: map()
  def serialize_view(%{} = view) do
    view
    |> Map.take([
      :provider,
      :provider_account_id,
      :account,
      :workspaces,
      :workspace_id,
      :status_5h,
      :status_7d,
      :overage_status,
      :representative_claim,
      :per_model_utilization,
      :extra_usage,
      :oauth_utilization_5h,
      :oauth_utilization_7d,
      :capture_source,
      :utilization_5h,
      :utilization_7d,
      :primary_label,
      :secondary_label,
      :plan,
      :message,
      :models,
      :cost_usd,
      :estimate
    ])
    |> Map.merge(%{
      reset_5h_at: iso(view[:reset_5h_at]),
      reset_7d_at: iso(view[:reset_7d_at]),
      captured_at: iso(view[:captured_at]),
      oauth_captured_at: iso(view[:oauth_captured_at])
    })
  end

  @doc """
  The installation default workspace id: the lone workspace when there is
  exactly one, else the one named "default". `{:error, reason}` when ambiguous
  or empty. A display / pipeline-attribution default only — it is
  `Arbiter.Tasks.Workspaces.default_id/0`, never how a request's workspace is
  resolved (that is `Workspaces.resolve/3`).
  """
  @spec default_workspace_id() :: {:ok, String.t()} | {:error, term()}
  defdelegate default_workspace_id(), to: Arbiter.Tasks.Workspaces, as: :default_id

  @doc """
  The installation default workspace itself — `default_workspace_id/0`'s rule,
  but handing back the row the one read already loaded, so a caller that also
  needs the workspace's config does not read `workspaces` a second time.
  """
  @spec default_workspace() :: {:ok, Workspace.t()} | {:error, term()}
  defdelegate default_workspace(), to: Arbiter.Tasks.Workspaces, as: :default

  @doc """
  The `on_exhaustion` mode (`:throttle` / `:continue`) for the installation
  default workspace (bd-l4epbc) — used by the quota-bar UI to word the
  pace-warning label ("stalls in Nm" vs "starts billing overage in Nm")
  without threading the workspace record through every LiveView. Falls back
  to `Workspace.quota_on_exhaustion(nil)` (global default) when the default
  workspace can't be resolved.
  """
  @spec default_workspace_on_exhaustion() :: :throttle | :continue
  def default_workspace_on_exhaustion do
    case default_workspace() do
      {:ok, workspace} -> Workspace.quota_on_exhaustion(workspace)
      _ -> Workspace.quota_on_exhaustion(nil)
    end
  end

  # ---- internals ---------------------------------------------------------

  defp resolve_workspace_id(ws_id) when is_binary(ws_id) and ws_id != "", do: {:ok, ws_id}
  defp resolve_workspace_id(_), do: default_workspace_id()

  # Pull the `anthropic-ratelimit-unified-*` family out of a response header
  # list into AnthropicQuota attrs. Unknown / absent headers are simply left
  # out, so the returned map is empty when nothing relevant was present.
  @doc false
  @spec parse_unified_headers([{String.t(), String.t()}]) :: map()
  def parse_unified_headers(headers) do
    index =
      for {name, value} <- headers,
          into: %{},
          do: {String.downcase(to_string(name)), to_string(value)}

    %{}
    |> put_float(:utilization_5h, index, "anthropic-ratelimit-unified-5h-utilization")
    |> put_reset(:reset_5h_at, index, "anthropic-ratelimit-unified-5h-reset")
    |> put_string(:status_5h, index, "anthropic-ratelimit-unified-5h-status")
    |> put_float(:utilization_7d, index, "anthropic-ratelimit-unified-7d-utilization")
    |> put_reset(:reset_7d_at, index, "anthropic-ratelimit-unified-7d-reset")
    |> put_string(:status_7d, index, "anthropic-ratelimit-unified-7d-status")
    |> put_string(
      :representative_claim,
      index,
      "anthropic-ratelimit-unified-representative-claim"
    )
    |> put_string(:overage_status, index, "anthropic-ratelimit-unified-overage-status")
  end

  defp put_float(acc, key, index, header) do
    case Map.get(index, header) do
      nil ->
        acc

      raw ->
        case Float.parse(raw) do
          {f, _} -> Map.put(acc, key, f)
          :error -> acc
        end
    end
  end

  defp put_string(acc, key, index, header) do
    case Map.get(index, header) do
      nil -> acc
      "" -> acc
      raw -> Map.put(acc, key, raw)
    end
  end

  # The reset headers are unix epoch seconds.
  defp put_reset(acc, key, index, header) do
    with raw when is_binary(raw) <- Map.get(index, header),
         {secs, _} <- Integer.parse(raw),
         {:ok, dt} <- DateTime.from_unix(secs) do
      Map.put(acc, key, DateTime.truncate(dt, :second))
    else
      _ -> acc
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # `Kernel.max/2` spelled out: `use Ash.Domain` defines a `max` aggregate here.
  defp age_seconds(%DateTime{} = at),
    do: Kernel.max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

  defp age_seconds(_), do: nil
end
