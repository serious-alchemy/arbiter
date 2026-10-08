defmodule Arbiter.Board.CapacityExplainer do
  @moduledoc """
  Says, in plain English, why the board's slot cap is what it is and why a
  Ready card is waiting (bd-5fl9sx). Presentation only: nothing here decides
  anything the scheduler does not already decide.

  ## It reads the scheduler's own numbers

  The cap is the minimum of several limits — machine capacity (the local cap
  plus every available node), the install-wide ceiling, the workspace's
  `conductor.max_concurrent`, where the workspace's work may run, and the
  provider account's headroom. `Arbiter.Board.Snapshot.capacity_terms/3` is
  the one function that folds them, and `effective_max_concurrent/3` *is*
  its `effective`; `Snapshot.load/1` keeps the terms on the board (`capacity`)
  beside `slots_total`. This module formats those terms and names the binding
  one, so an explanation cannot disagree with the number it explains.

  Likewise a held Ready card carries the scheduler's structured hold
  (`Arbiter.Board.Scheduler.plan/1`'s `hold`), not just its phrase, so the
  kind of hold is never recovered from prose. The one exception is a
  provider-constraint or quota hold's *detail*, which the routing layer only
  produces as a sentence; its capacity-vs-paused flavour is read from the
  words it uses, and the sentence itself is always kept as `details` for
  debugging.

  ## Shapes

  `cap/2` → `%{effective:, used:, free:, binding:, headline:, limits: [...],
  users: [...], parked: n}`; `hold/3` → `%{kind:, badge:, summary:, details:}`.
  `kind` is `:capacity`, `:quota`, `:auth`, `:paused_provider`,
  `:provider_constraint` or `:scheduler_paused`; `badge` is the short label a
  card wears and `summary` the sentence(s) for its popup. Every string is
  for an operator: no atoms, tuples or setting names where a phrase will do
  (the commands that change a limit are the one place a name is wanted).
  """

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.SlotLimit

  @capacity_badge "Waiting for capacity"

  @doc "The badge every capacity-held card wears."
  @spec capacity_badge() :: String.t()
  def capacity_badge, do: @capacity_badge

  @doc """
  The whole board's explanations in one pass, for the async load: the cap
  popup and one hold explanation per held Ready card and per quota-held
  Blocked card (`%{ticket_id => hold}`).
  """
  @spec explain(map()) :: %{cap: map() | nil, holds: %{String.t() => map()}}
  def explain(board) when is_map(board) do
    # Only the holds that have something to say: a mutex or file-overlap hold
    # is already one short line on its card.
    ready =
      for %{id: id, hold: hold} = entry <- Map.get(board, :ready, []),
          hold != nil,
          explained =
            hold(hold, board, raw: entry.reason, workspace_id: entry.card[:workspace_id]),
          explained.kind != :other,
          into: %{} do
        {id, explained}
      end

    quota_held =
      for %{id: id, hold: %{reason: reason} = hold} <- Map.get(board, :blocked, []), into: %{} do
        {id, dispatch_queue_hold(hold, reason)}
      end

    %{cap: cap(board), holds: Map.merge(ready, quota_held)}
  end

  # ---- the cap ----------------------------------------------------------------

  @doc """
  The slot cap, input by input, with the binding one marked and every ticket
  holding a slot listed. `nil` when the board carries no capacity terms.
  """
  @spec cap(map(), keyword()) :: map() | nil
  def cap(board, opts \\ [])

  def cap(%{capacity: %{} = terms} = board, _opts) do
    account = account_detail(terms)

    limits =
      terms
      |> limit_keys()
      |> Enum.map(fn key ->
        %{
          key: key,
          binding?: key == terms.binding,
          text: limit_text(key, terms, account),
          change: change_hint(key, terms, account)
        }
      end)

    users = users(board)

    %{
      effective: terms.effective,
      used: Map.get(board, :slots_used, 0),
      free: Map.get(board, :slots_free, 0),
      binding: terms.binding,
      headline: headline(terms, account),
      limits: limits,
      users: users,
      parked: Enum.count(users, &(&1.state == :parked))
    }
  end

  def cap(_board, _opts), do: nil

  # Which limits to list: the machine total always, the rest only when they
  # exist for this board — an unset limit is not an input.
  defp limit_keys(terms) do
    present = Keyword.keys(terms.terms)

    [:nodes, :ceiling, :workspace, :placement, :placement_free, :account]
    |> Enum.filter(&(&1 in present or (&1 == :account and terms.account != nil)))
    |> Enum.reject(&(&1 == :placement and trivial_placement?(terms)))
  end

  # A workspace that runs on this machine only: its placement term is just the
  # local cap again, which the machine line already says.
  defp trivial_placement?(%{placement: %{mode: :local_only}}), do: true
  defp trivial_placement?(_), do: false

  defp headline(%{binding: :nodes} = t, _a),
    do: "The cap is #{t.effective}: that is all the machine capacity there is."

  defp headline(%{binding: :ceiling} = t, _a),
    do: "Limited to #{t.effective} by the install-wide limit."

  defp headline(%{binding: :workspace} = t, _a),
    do: "Limited to #{t.effective} by the workspace setting."

  defp headline(%{binding: :placement} = t, _a),
    do: "Limited to #{t.effective} by where this workspace's work may run."

  defp headline(%{binding: :placement_free} = t, _a),
    do:
      "Limited to #{t.effective} for now: the machines this workspace may use have no more free slots."

  defp headline(%{binding: :account} = t, account) do
    "Limited to #{t.effective} by the #{account_phrase(t, account)}" <>
      account_fill(account) <> "."
  end

  defp limit_text(:nodes, %{install: install}, _account) do
    machines =
      Enum.map_join(install.nodes, "", fn node ->
        " + #{node.name || "a node"} (#{node.contributes}#{node_reason(node)})"
      end)

    "Capacity #{install.sum} = this machine (#{install.local})#{machines}" <> remote_off(install)
  end

  defp limit_text(:ceiling, %{install: %{ceiling: ceiling, sum: sum}}, _account) do
    cut = if ceiling < sum, do: ", below the #{sum} the machines could run", else: ""
    "Install-wide limit: #{ceiling}#{cut}"
  end

  defp limit_text(:workspace, %{workspace: %{max: max}}, _account),
    do: "Workspace setting: at most #{max} at once"

  defp limit_text(:placement, %{placement: placement}, _account),
    do:
      "Where this workspace's work may run (#{mode_phrase(placement.mode)}): up to #{placement.cap}"

  defp limit_text(:placement_free, %{placement: placement}, _account),
    do:
      "Free slots on #{mode_machines(placement.mode)}: #{placement.free} (the tickets already running count too)"

  defp limit_text(:account, terms, account), do: account_line(terms, account)

  defp remote_off(%{remote_execution?: false}),
    do: " (remote workers are switched off, so nodes add nothing)"

  defp remote_off(_), do: ""

  defp node_reason(%{reason: nil}), do: ""
  defp node_reason(%{reason: :remote_execution_off}), do: ", remote workers off"
  defp node_reason(%{reason: :unhealthy}), do: ", not healthy"
  defp node_reason(%{reason: :no_cap}), do: ", no worker cap set"
  defp node_reason(%{reason: state}), do: ", #{state}"

  defp mode_phrase(:local_only), do: "this machine only"
  defp mode_phrase(:prefer_remote), do: "this machine and the nodes"
  defp mode_phrase(:remote_only), do: "the nodes only"
  defp mode_phrase(other), do: to_string(other)

  defp mode_machines(:remote_only), do: "the nodes"
  defp mode_machines(_), do: "this machine and the nodes"

  # ---- the account term ---------------------------------------------------------

  # The reads that name the account's current users. Done here, not in the
  # terms, so a board refresh with room to spare pays nothing for them.
  defp account_detail(%{account: %{kind: :account} = account, workspace: %{id: ws_id}}) do
    resolved = Resolver.account(ws_id, account.provider)
    Map.put(account, :runs, if(resolved, do: Concurrency.holders(resolved), else: []))
  rescue
    _ -> Map.put(account, :runs, [])
  end

  defp account_detail(%{account: account}), do: account

  defp account_phrase(_terms, %{kind: :account, provider: provider, name: name}),
    do: "#{provider_label(provider)} account (#{name})"

  defp account_phrase(_terms, %{kind: :routed}), do: "provider accounts"
  defp account_phrase(_terms, _), do: "provider account"

  defp account_fill(%{kind: :account, limit: limit, runs: runs}) when is_integer(limit),
    do: ": #{length(runs)} of #{limit} in use"

  defp account_fill(_), do: ""

  defp account_line(_terms, %{kind: :account, limit: nil, provider: provider, name: name}),
    do: "#{provider_label(provider)} account (#{name}): no limit set"

  defp account_line(terms, %{kind: :account} = account) do
    "#{String.capitalize(account_phrase(terms, account))}#{account_fill(account)}"
  end

  defp account_line(_terms, %{kind: :routed, names: names, capacity: capacity}),
    do: "Provider accounts (#{Enum.join(names, ", ")}): room for #{capacity} at once"

  # ---- what changes each limit ---------------------------------------------------

  defp change_hint(:nodes, _terms, _a),
    do:
      "Change with `arb node set local --max-workers N` (this machine) or `arb node set <node> --max-workers N`."

  defp change_hint(:ceiling, _terms, _a),
    do:
      "Change with `arb settings set conductor_system_max_concurrent N`, or clear it with `arb settings unset conductor_system_max_concurrent`."

  defp change_hint(:workspace, _terms, _a),
    do: "Change with `arb config set conductor.max_concurrent N`."

  defp change_hint(:placement, _terms, _a),
    do: "Change with `arb config set worker.placement local_only|prefer_remote|remote_only`."

  defp change_hint(:placement_free, _terms, _a),
    do: "Frees up as runs finish; raise a node's cap with `arb node set <node> --max-workers N`."

  defp change_hint(:account, _terms, %{kind: :account, name: name}),
    do: "Change with `arb account set #{name} --max-concurrent N`."

  defp change_hint(:account, _terms, _a),
    do: "Change with `arb account set <account> --max-concurrent N`."

  # ---- who is using the slots -----------------------------------------------------

  defp users(board) do
    cards = Map.new(Map.get(board, :in_progress, []), &{&1.id, &1})

    for id <- Map.get(board, :slot_holders, []) do
      card = Map.get(cards, id, %{})
      title = Map.get(card, :title)

      if Map.get(card, :agent_live) == true do
        %{id: id, title: title, state: :running, text: "agent running"}
      else
        %{
          id: id,
          title: title,
          state: :parked,
          text: "parked: no agent is running, but it still holds a slot"
        }
      end
    end
  end

  # ---- a held card -------------------------------------------------------------------

  @doc """
  The explanation of one Ready card's `hold` (the scheduler's term), against
  `board`. `opts[:raw]` is the scheduler's own phrase, kept as `details`.
  """
  @spec hold(term(), map(), keyword()) :: map()
  def hold(hold, board, opts \\ [])

  def hold(:no_slot, board, opts) do
    terms = Map.get(board, :capacity)
    account = terms && account_detail(terms)

    %{
      kind: :capacity,
      badge: @capacity_badge,
      summary: no_slot_summary(terms, account, Map.get(board, :slot_holders, [])),
      details: opts[:raw]
    }
  end

  def hold({:provider_constraint, detail}, _board, opts) do
    cond do
      String.contains?(detail, "paused") ->
        %{
          kind: :paused_provider,
          badge: "Paused provider",
          summary:
            "#{constraint_phrase(detail)}Every provider this ticket may use is paused, so it " <>
              "cannot start. It starts once one of them is resumed on the Providers page.",
          details: opts[:raw] || detail
        }

      String.contains?(detail, "at capacity") or String.contains?(detail, "free slot") ->
        %{
          kind: :capacity,
          badge: @capacity_badge,
          summary: constraint_capacity_summary(detail, opts[:workspace_id]),
          details: opts[:raw] || detail
        }

      true ->
        %{
          kind: :provider_constraint,
          badge: "Provider restriction",
          summary:
            "#{constraint_phrase(detail)}No provider it may use is available. Change the " <>
              "ticket's provider restriction, or wait for an allowed provider.",
          details: opts[:raw] || detail
        }
    end
  end

  def hold({:quota, reason}, _board, opts) do
    if String.contains?(reason, "auth hold") do
      %{
        kind: :auth,
        badge: "Auth hold",
        summary:
          "The provider's login failed several times in a row, so new work is held until " <>
            "its credentials are fixed. Check the Providers page.",
        details: opts[:raw] || reason
      }
    else
      %{
        kind: :quota,
        badge: "Quota hold",
        summary:
          "The provider's quota is too used up to start new work right now (#{reason}). " <>
            "The scheduler starts it on its own when the quota window allows.",
        details: opts[:raw] || reason
      }
    end
  end

  def hold(:paused, _board, opts) do
    %{
      kind: :scheduler_paused,
      badge: "Scheduler paused",
      summary:
        "The scheduler is paused, so nothing is being started. Running work is not affected. " <>
          "Resume it with the scheduler button at the top of the board.",
      details: opts[:raw]
    }
  end

  def hold(other, _board, opts) do
    phrase = Arbiter.Tasks.Lifecycle.describe_hold(other)
    %{kind: :other, badge: phrase, summary: phrase, details: opts[:raw] || phrase}
  end

  # A Blocked-column ticket the quota gate is holding between rounds
  # (`Arbiter.Workflows.DispatchQueue`): its agent is gone and it gave its slot back.
  defp dispatch_queue_hold(%{resumes_at: resumes_at}, reason) do
    resume =
      case resumes_at do
        %DateTime{} = at ->
          " It resumes on its own around #{Calendar.strftime(at, "%H:%M")} UTC."

        _ ->
          " It resumes on its own when the quota window allows."
      end

    %{
      kind: :quota,
      badge: "Quota hold",
      summary:
        "This ticket is already In progress, but its next round is waiting on the " <>
          "provider's quota. It gave its slot back meanwhile." <> resume,
      details: reason
    }
  end

  # ---- wording the capacity holds --------------------------------------------------------

  defp no_slot_summary(nil, _account, holders),
    do: "Waiting for a free worker slot#{using(holders)}. It starts when one finishes."

  defp no_slot_summary(%{binding: :account} = terms, %{kind: :account} = account, holders) do
    runs = account |> Map.get(:runs, []) |> account_runs(holders)

    "Waiting for a #{provider_label(account.provider)} slot. The " <>
      "#{account_phrase(terms, account)} allows #{limit_word(account)} at once and " <>
      "#{in_use(account.limit, length(Map.get(account, :runs, [])))} in use#{runs}. " <>
      "It starts when one finishes."
  end

  defp no_slot_summary(%{binding: binding} = terms, _account, holders) do
    "Waiting for a free worker slot. #{binding_reason(binding, terms)}#{using(holders)}. " <>
      "It starts when one finishes."
  end

  defp binding_reason(:workspace, t),
    do: "The workspace allows #{t.effective} at once and they are all in use"

  defp binding_reason(:ceiling, t),
    do: "The install-wide limit is #{t.effective} at once and they are all in use"

  defp binding_reason(:placement_free, _t),
    do: "The machines this workspace may use have no free slot"

  defp binding_reason(:placement, t),
    do: "This workspace may only use #{t.effective} slots and they are all in use"

  defp binding_reason(_nodes, t),
    do: "All #{t.effective} slots on the available machines are in use"

  defp in_use(1, 1), do: "it is"
  defp in_use(limit, live) when limit == live, do: "all are"
  defp in_use(_limit, live), do: "#{live} are"

  defp limit_word(%{limit: limit}) when is_integer(limit), do: to_string(limit)
  defp limit_word(_), do: "a limited number"

  defp account_runs([], holders), do: using(holders)
  defp account_runs(keys, _holders), do: " (#{SlotLimit.runs(keys)})"

  defp using([]), do: ""
  defp using(holders), do: " (held by #{Enum.join(holders, ", ")})"

  defp constraint_phrase(detail) do
    case Regex.run(~r/^(require|exclude) ([^:]+):/, detail) do
      [_, verb, providers] -> "This ticket has a provider restriction (#{verb} #{providers}). "
      _ -> ""
    end
  end

  # The common case on a real board: the ticket's provider(s) are all on full
  # accounts. Name each full account, its limit and the runs filling it — the
  # same reads `SlotLimit` uses for a full workspace.
  defp constraint_capacity_summary(detail, workspace_id) do
    accounts = full_accounts(detail, workspace_id)

    lead =
      case accounts |> Enum.map(& &1.provider) |> Enum.uniq() do
        [provider] -> "Waiting for a #{provider_label(provider)} slot."
        _ -> "Waiting for a slot on an allowed provider."
      end

    now =
      case accounts do
        [] -> "Every provider it may use is full right now."
        _ -> Enum.map_join(accounts, " ", &account_full_sentence/1)
      end

    "#{lead} #{constraint_phrase(detail)}#{now} It starts when one finishes."
  end

  defp account_full_sentence(%{limit: limit, runs: runs} = account)
       when is_integer(limit) and runs != [] do
    "The #{provider_label(account.provider)} account (#{account.name}) allows #{limit} at once " <>
      "and #{in_use(limit, length(runs))} in use (#{SlotLimit.runs(runs)})."
  end

  defp account_full_sentence(account),
    do: "The #{provider_label(account.provider)} account (#{account.name}) is full right now."

  # `claude:default at capacity` in the routing layer's sentence, resolved back
  # to the account the workspace is metered under for that provider.
  defp full_accounts(detail, workspace_id) do
    ~r/([a-z0-9_]+):([A-Za-z0-9_.-]+) at capacity/
    |> Regex.scan(detail, capture: :all_but_first)
    |> Enum.uniq()
    |> Enum.map(fn [provider, slug] ->
      full_account(provider, "#{provider}:#{slug}", workspace_id)
    end)
  end

  defp full_account(provider, name, workspace_id) do
    base = %{provider: provider, name: name, limit: nil, runs: []}

    with ws when is_binary(ws) <- workspace_id,
         %{provider: p, slug: slug} = account <- Resolver.account(ws, provider),
         true <- "#{p}:#{slug}" == name do
      %{base | limit: Concurrency.limit(account, ws), runs: Concurrency.holders(account)}
    else
      _ -> base
    end
  rescue
    _ -> %{provider: provider, name: name, limit: nil, runs: []}
  end

  defp provider_label(nil), do: "provider"
  defp provider_label(provider), do: provider |> to_string() |> String.capitalize()
end
