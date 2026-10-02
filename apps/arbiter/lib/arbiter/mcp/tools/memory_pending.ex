defmodule Arbiter.MCP.Tools.MemoryPending do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for the shared-memory promotion queue and its
  quarantine (bd-19qve3, RFC §9.4 phase 13): `memory_pending_list` /
  `memory_pending_diff` / `memory_pending_apply` / `memory_pending_reject`,
  modelled on `loop_pending_*`, plus `memory_quarantine_list` /
  `memory_quarantine_restore`, and `memory_distill` (bd-avt4lt, phase 14),
  which proposes candidates from an ended session's transcript. The domain
  logic lives in `Arbiter.Sessions.Memory.Promotion`,
  `Arbiter.Sessions.Memory.Quarantine` and
  `Arbiter.Sessions.TranscriptDistillation`.

  ## Who may write

  Every tool is coordinator-tier in the catalog. The three that write into the
  shared layer every future session reads, apply, reject and restore, are
  further restricted to a **plain** coordinator token, the coordinator or the
  operator's own tooling. A browser-hosted session's token is also
  coordinator-tier (`Arbiter.MCP.Scope.mint_session/2`) but carries a
  `session_id`, and it is refused here. A session writes candidates. It never
  promotes them, its own or another session's, and never clears a rejection or
  a quarantine. The read tools stay open to session tokens: reading the queue
  changes nothing.

  `memory_distill` is plain-coordinator only as well. It never touches the
  shared layer, but it spends model budget and reads another session's
  transcript. Its optional bounds can lower the configured caps
  (`Arbiter.Sessions.TranscriptDistillation.settings/0`), never raise them.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.PaperTrail
  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.Sessions.Memory.Quarantine
  alias Arbiter.Sessions.TranscriptDistillation

  @states %{"pending" => :pending, "rejected" => :rejected}

  @doc "Queued candidates (state `pending`, the default) or rejected ones (state `rejected`)."
  @spec memory_pending_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_pending_list(%Scope{}, args) do
    with {:ok, state} <- state_arg(args) do
      candidates = Promotion.list_candidates(state: state)
      {:ok, %{candidates: candidates, count: length(candidates)}}
    end
  end

  @doc "One candidate in full, its diff against the shared memory it replaces, and its verification."
  @spec memory_pending_diff(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_pending_diff(%Scope{}, args) do
    with {:ok, id} <- Tools.require_string(args, "id") do
      case Promotion.diff(id) do
        {:ok, result} -> {:ok, Map.update!(result, :verification, &serialize_verdict/1)}
        {:error, reason} -> {:error, promotion_error(id, reason)}
      end
    end
  end

  @doc "Promote a candidate into the shared layer. Plain coordinator token only."
  @spec memory_pending_apply(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_pending_apply(%Scope{} = scope, args) do
    with :ok <- authorize_write(scope),
         {:ok, id} <- Tools.require_string(args, "id"),
         {:ok, overwrite?} <- Tools.fetch_bool(args, "overwrite", false) do
      case Promotion.promote(id, overwrite: overwrite?, actor: PaperTrail.actor_label(scope)) do
        {:ok, %{memory: memory, verdict: verdict}} ->
          {:ok, Map.merge(%{id: id, memory: memory, promoted: true}, serialize_verdict(verdict))}

        {:error, reason} ->
          {:error, promotion_error(id, reason)}
      end
    end
  end

  @doc "Reject a candidate with a reason; it is marked and kept. Plain coordinator token only."
  @spec memory_pending_reject(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_pending_reject(%Scope{} = scope, args) do
    with :ok <- authorize_write(scope),
         {:ok, id} <- Tools.require_string(args, "id"),
         {:ok, reason} <- Tools.require_string(args, "reason") do
      case Promotion.reject(id, reason, actor: PaperTrail.actor_label(scope)) do
        {:ok, %{path: path}} -> {:ok, %{id: id, rejected: true, kept_at: path}}
        {:error, reason} -> {:error, promotion_error(id, reason)}
      end
    end
  end

  @doc "Quarantined memories, with the reason, SHA and time each was quarantined."
  @spec memory_quarantine_list(Scope.t(), map()) :: {:ok, map()}
  def memory_quarantine_list(%Scope{}, _args) do
    entries = Quarantine.list(Paths.memory_root())
    {:ok, %{quarantined: entries, count: length(entries)}}
  end

  @doc "Re-verify a quarantined memory and serve it again if nothing is stale. Plain coordinator token only."
  @spec memory_quarantine_restore(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_quarantine_restore(%Scope{} = scope, args) do
    with :ok <- authorize_write(scope),
         {:ok, name} <- Tools.require_string(args, "name"),
         {:ok, reanchor?} <- Tools.fetch_bool(args, "reanchor", false) do
      opts = [reanchor: reanchor?, actor: PaperTrail.actor_label(scope)]

      case Quarantine.restore(Paths.memory_root(), name, opts) do
        {:ok, %{memory: memory, verdict: verdict}} ->
          {:ok,
           Map.merge(%{name: name, memory: memory, restored: true}, serialize_verdict(verdict))}

        {:error, reason} ->
          {:error, restore_error(name, reason)}
      end
    end
  end

  @doc """
  One transcript distillation pass over an ended session: candidates go into
  the queue above, nothing reaches the shared layer. Plain coordinator token
  only.
  """
  @spec memory_distill(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def memory_distill(%Scope{} = scope, args) do
    with :ok <- authorize_distill(scope),
         {:ok, session_id} <- Tools.require_string(args, "session_id"),
         {:ok, opts} <- distill_opts(args) do
      case TranscriptDistillation.run(session_id, opts) do
        {:ok, result} -> {:ok, serialize_distillation(result)}
        {:error, reason} -> {:error, distill_error(session_id, reason)}
      end
    end
  end

  # ---- authorization ---------------------------------------------------------

  defp authorize_write(%Scope{tier: :coordinator, session_id: nil}), do: :ok

  defp authorize_write(%Scope{tier: :coordinator}) do
    {:error,
     {:unauthorized,
      "a session token cannot write the shared memory layer: promotion, rejection and " <>
        "restore are coordinator/operator only"}}
  end

  defp authorize_write(%Scope{tier: tier}) do
    {:error, {:unauthorized, "the shared memory layer is coordinator/operator only, not #{tier}"}}
  end

  defp authorize_distill(%Scope{tier: :coordinator, session_id: nil}), do: :ok

  defp authorize_distill(%Scope{tier: :coordinator}) do
    {:error,
     {:unauthorized,
      "a session token cannot run transcript distillation: it spends model budget and reads " <>
        "another session's transcript, so it is coordinator/operator only"}}
  end

  defp authorize_distill(%Scope{tier: tier}) do
    {:error, {:unauthorized, "transcript distillation is coordinator/operator only, not #{tier}"}}
  end

  # ---- arguments and errors ----------------------------------------------------

  defp state_arg(args) do
    case Map.get(args, "state", "pending") do
      state when is_map_key(@states, state) -> {:ok, Map.fetch!(@states, state)}
      _ -> {:error, {:invalid, "`state` must be one of: pending, rejected"}}
    end
  end

  defp distill_opts(args) do
    settings = TranscriptDistillation.settings()

    with {:ok, max_bytes} <- positive_integer(args, "max_bytes"),
         {:ok, from_turn} <- positive_integer(args, "from_turn"),
         {:ok, max_candidates} <- positive_integer(args, "max_candidates"),
         {:ok, max_cost_usd} <- positive_number(args, "max_cost_usd") do
      {:ok,
       [
         max_bytes: lower(max_bytes, settings[:max_bytes]),
         from_turn: from_turn,
         max_candidates: lower(max_candidates, settings[:max_candidates]),
         max_cost_usd: lower(max_cost_usd, settings[:max_cost_usd])
       ]}
    end
  end

  # A caller may tighten a configured cap, never loosen it.
  defp lower(nil, _configured), do: nil
  defp lower(value, configured), do: min(value, configured)

  defp positive_integer(args, key) do
    case Tools.optional_integer(args, key) do
      {:ok, n} when is_nil(n) or n > 0 -> {:ok, n}
      {:ok, _n} -> {:error, {:invalid, "`#{key}` must be a positive integer"}}
      error -> error
    end
  end

  defp positive_number(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      n when is_number(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid, "`#{key}` must be a positive number"}}
    end
  end

  defp serialize_distillation(result) do
    %{
      session_id: result.session_id,
      source_transcript: result.source_transcript,
      window: result.window,
      candidates: Enum.map(result.candidates, &Map.take(&1, [:id, :name, :type, :turn_range])),
      count: length(result.candidates),
      rejected: Enum.map(result.rejected, &%{&1 | reason: reason_text(&1.reason)}),
      cost: %{
        usage_event_id: result.cost.usage_event_id,
        cost_usd: result.cost.cost_usd,
        max_cost_usd: result.cost.max_cost_usd,
        over_budget: result.cost.over_budget?
      }
    }
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp distill_error(_id, :invalid_session_id),
    do: {:invalid, "`session_id` must be a session id, as the sessions list shows it"}

  defp distill_error(id, :no_archived_transcript) do
    {:not_found,
     "session #{id} has no archived transcript: a session is archived when it ends, and only a " <>
       "Claude Code session has one"}
  end

  defp distill_error(id, :empty_transcript),
    do: {:invalid, "session #{id}'s transcript has no conversation turns to distill"}

  defp distill_error(_id, :model_calls_disabled),
    do: {:unavailable, "transcript distillation model calls are disabled on this server"}

  defp distill_error(_id, {:budget_exhausted, spend}) do
    {:budget_exhausted,
     "transcript distillation has spent $#{spend.spent_usd} in the last 24 hours; another pass " <>
       "of up to $#{spend.max_cost_usd} would pass the $#{spend.daily_budget_usd} daily budget"}
  end

  defp distill_error(id, :unsafe_candidates_dir),
    do: {:invalid, "session #{id}'s candidate space is not a plain directory; refusing to write"}

  defp distill_error(_id, :unparseable_model_output) do
    {:model_error,
     "the model's reply held no candidates JSON; the pass was metered and queued nothing"}
  end

  defp distill_error(_id, {:invalid_option, key}),
    do: {:invalid, "transcript distillation is misconfigured: `#{key}` is not a valid bound"}

  defp distill_error(_id, reason), do: {:system_error, inspect(reason)}

  defp promotion_error(id, :invalid_id),
    do:
      {:invalid,
       "`id` must be `<session-id>/<file>.md` exactly as memory_pending_list shows it: #{id}"}

  defp promotion_error(id, :not_found), do: {:not_found, "no pending candidate #{id}"}

  defp promotion_error(id, :exists) do
    {:conflict,
     "a shared memory named like #{id} already exists; pass `overwrite: true` to replace it " <>
       "(the replaced copy is kept under .superseded/)"}
  end

  defp promotion_error(id, :too_large),
    do: {:invalid, "candidate #{id} is larger than a memory should be"}

  defp promotion_error(_id, :reason_required), do: {:invalid, "`reason` is required"}

  defp promotion_error(id, {:invalid_memory, why}),
    do: {:invalid, "candidate #{id} cannot be mounted: #{why}"}

  defp promotion_error(id, {:stale, verdict}),
    do: {:stale, stale_message("candidate #{id}", verdict)}

  defp promotion_error(_id, {:system_error, reason}), do: {:system_error, inspect(reason)}

  defp restore_error(name, :invalid_name),
    do: {:invalid, "`name` must be a file name from memory_quarantine_list: #{name}"}

  defp restore_error(name, :not_found), do: {:not_found, "nothing quarantined as #{name}"}

  defp restore_error(name, :exists) do
    {:conflict,
     "a live memory already holds the name #{name} was quarantined from; resolve that first"}
  end

  defp restore_error(name, {:stale, verdict}) do
    {:stale,
     stale_message(
       "#{name} is still stale (fix its citations, or pass `reanchor: true`)",
       verdict
     )}
  end

  defp restore_error(_name, reason), do: {:system_error, inspect(reason)}

  defp stale_message(subject, verdict), do: "#{subject}: #{Enum.join(verdict.reasons, "; ")}"

  defp serialize_verdict(verdict) do
    %{
      status: Atom.to_string(verdict.status),
      checked_against: verdict.checked_against,
      citations: verdict.citations,
      reasons: verdict.reasons
    }
  end
end
