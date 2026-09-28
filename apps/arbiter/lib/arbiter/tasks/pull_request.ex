defmodule Arbiter.Tasks.PullRequest do
  @moduledoc """
  A ticket's open pull request (bd-741sid, ticket lifecycle 4/13).

  The ticket owns its PR's state. What a worker parked at `:awaiting_review`
  used to hold in memory now lives on the `Arbiter.Tasks.Issue` row, so no
  worker has to stay resident while the PR is open, and the ticket's
  `Arbiter.Worker.Watchdog` can be restarted from the row alone:

  | field | what |
  |---|---|
  | `pr_ref` | the PR/MR ref (existing column) |
  | `merger_url` | its clickable URL |
  | `merger_status` / `merger_checked_at` | the forge's last answer and when it was read |
  | `merge_watch` | the lane the Watchdog watches it on |
  | `last_reviewed_sha` | the ReviewGate's approved head (existing column) |
  | `review_gate_state` | the ReviewGate round state |

  The maps are stored as JSON, so they come back with string keys. Everything
  here writes them string-keyed, and reads them back through
  `merger_status/1`, which only turns a value back into an atom when it is one
  the adapters are known to produce.

  A ticket pulled out of the merge queue (`pull/1`) stays Merging with its PR
  open, but the pull is recorded on its lane and nothing restarts its Watchdog
  on its own until an operator does (`Arbiter.Worker.Watchdog.restart/2`).
  """

  alias Arbiter.Mergers
  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Watchdog

  require Ash.Query
  require Logger

  @topic "pull_requests"

  # The slice of an adapter's `get/1` result worth keeping on the ticket. The
  # rest (the PR's title and body, its author) is either large or only read
  # once, at the poll that fetched it.
  @status_keys ~w(status approved changes_requested ci_clean conflicting block_reason pipeline head_sha base_ref)a

  # Atom-valued fields, and the atoms each may hold. A value outside its list
  # stays a string rather than minting an atom from a DB value.
  @status_atoms %{
    status: [:open, :merged, :closed],
    block_reason: [
      :conflict,
      :behind_base,
      :ci_failed,
      :needs_approval,
      :needs_nonauthor_approval,
      :draft,
      :blocked_other
    ],
    pipeline: [
      :success,
      :failed,
      :running,
      :pending,
      :not_started,
      :neutral,
      :canceled,
      :skipped,
      :manual,
      :created
    ]
  }

  @doc """
  The PubSub topic a change to a ticket's PR is announced on, as
  `{:pull_request, event, task_id}`. Kept off `"tasks"`: the Watchdog's poll
  lands here every interval for every open PR, and the scheduler replans on
  every `"tasks"` message.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Record the forge's latest answer about the ticket's PR — the Watchdog calls
  this on every poll — with the time it was read.
  """
  @spec record_merger_status(String.t(), map()) :: :ok | {:error, term()}
  def record_merger_status(task_id, status) when is_binary(task_id) and is_map(status) do
    attrs = %{merger_status: encode_status(status), merger_checked_at: DateTime.utc_now()}

    with {:ok, issue} <- Ash.get(Issue, task_id),
         {:ok, _updated} <- Ash.update(issue, attrs, action: :record_merger_status) do
      broadcast(:status, task_id)
    end
  end

  @doc """
  The ticket's last recorded merger status as an atom-keyed map (the shape
  `Arbiter.Mergers.get/1` returns), or `nil` when none was recorded.
  """
  @spec merger_status(Issue.t() | map() | nil) :: map() | nil
  def merger_status(%{merger_status: status}), do: decode_status(status)
  def merger_status(_), do: nil

  @doc """
  Merge `changes` into the ticket's ReviewGate round state. Keys are written
  as strings and atom values as their names, so the row reads back the same
  as it was written.
  """
  @spec record_review_gate(String.t(), map()) :: :ok | {:error, term()}
  def record_review_gate(task_id, changes) when is_binary(task_id) and is_map(changes) do
    with {:ok, issue} <- Ash.get(Issue, task_id),
         merged = Map.merge(issue.review_gate_state || %{}, stringify(changes)),
         {:ok, _updated} <-
           Ash.update(issue, %{review_gate_state: merged}, action: :record_review_gate) do
      :ok
    end
  end

  @doc """
  Every Merging ticket in the merge queue — each has an open PR its Watchdog
  owns — with the fields a merge-queue view reads: its PR, the forge's last
  answer, and when it last changed. A ticket pulled out of the queue
  (`pull/1`) is not listed.
  """
  @spec merging_tickets() :: [Issue.t()]
  def merging_tickets do
    Issue
    |> Ash.Query.filter(state == :merging)
    |> Ash.Query.select([
      :id,
      :title,
      :workspace_id,
      :state,
      :pr_ref,
      :merger_url,
      :merger_status,
      :merger_checked_at,
      :merge_watch,
      :updated_at,
      :created_at
    ])
    |> Ash.read!()
    |> Enum.reject(&pulled?/1)
  end

  # ---- the Watchdog's lane ----------------------------------------------------

  # The keys of `merge_watch`. Module-valued ones name the adapter that opened
  # the PR and an explicit auto-resume dispatcher; the rest are the lane flags
  # and the explicit merge/poll overrides a Watchdog was started with.
  # `review_only` marks a PR a review-only run adopted (bd-cw3w9p).
  @lane_keys ~w(adapter repo via_review_gate force_merge auto_merge local_head_sha reviewed_sha
                interval_ms initial_delay_ms max_polls auto_resume_dispatcher auto_resumes
                review_only)

  @doc """
  The `merge_watch` lane to record for a PR, from the options its Watchdog is
  started with. Modules are written by name; unknown keys are dropped.
  """
  @spec lane(keyword() | map()) :: map()
  def lane(opts) when is_list(opts) or is_map(opts) do
    opts
    |> Map.new(fn {key, value} -> {to_key(key), value} end)
    |> Map.take(@lane_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {key, value} when key in ["adapter", "auto_resume_dispatcher"] and is_atom(value) ->
        {key, Atom.to_string(value)}

      {key, value} ->
        {key, stringify(value)}
    end)
  end

  @doc """
  Record the reviewed-SHA baseline the ticket's Watchdog latched, so a
  Watchdog restarted from the row guards the merge on the same commit.
  """
  @spec record_reviewed_sha(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def record_reviewed_sha(task_id, sha) when is_binary(task_id) do
    update_lane(task_id, %{"reviewed_sha" => sha})
  end

  @doc """
  Record how many times the ticket's PR has been auto-resumed out of a
  review timeout, so the budget binds across Watchdogs.
  """
  @spec record_auto_resumes(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def record_auto_resumes(task_id, count) when is_binary(task_id) and is_integer(count) do
    update_lane(task_id, %{"auto_resumes" => count})
  end

  defp update_lane(task_id, changes) do
    with {:ok, issue} <- Ash.get(Issue, task_id),
         lane = Map.merge(issue.merge_watch || %{}, changes),
         {:ok, _updated} <- Ash.update(issue, %{merge_watch: lane}, action: :record_merge_watch) do
      :ok
    end
  end

  # ---- pulled out of the merge queue ------------------------------------------

  @doc """
  Pull the ticket's PR out of the merge queue: the board's gesture on a
  Merging card. The ticket stays Merging and its PR stays open, but nothing
  merges it on its own any more. Its Watchdog stops, the pending merge it
  stamped is dropped, and the pull is recorded on the lane
  (`merge_watch["pulled_at"]`).

  The mark is what makes the pull hold. The boot reconciler, the pending-merge
  sweeper and a finished pass all restart the Watchdog through
  `Arbiter.Worker.Watchdog.restart/2`, which refuses a pulled ticket. An
  operator's explicit restart puts it back (`clear_pull: true`), and so does a
  run that re-opens the PR, since that records a fresh lane.
  """
  @spec pull(String.t()) :: :ok | {:error, term()}
  def pull(task_id) when is_binary(task_id) do
    # The Watchdog stops before the mark is written: one mid-poll rewrites the
    # lane, and could write over it.
    :ok = Watchdog.stop(task_id)

    with :ok <- update_lane(task_id, %{"pulled_at" => DateTime.to_iso8601(DateTime.utc_now())}) do
      _ = PendingMerge.clear(task_id)
      # One the sweeper restarted between the stop and the mark.
      :ok = Watchdog.stop(task_id)
      broadcast(:pulled, task_id)
    end
  end

  @doc """
  Put a ticket `pull/1` took out of the merge queue back in it, by dropping
  the mark from its lane. It does not start the Watchdog: `Watchdog.restart/2`
  with `clear_pull: true` does both.
  """
  @spec clear_pull(String.t()) :: :ok | {:error, term()}
  def clear_pull(task_id) when is_binary(task_id) do
    with {:ok, issue} <- Ash.get(Issue, task_id) do
      if pulled?(issue) do
        lane = Map.delete(issue.merge_watch, "pulled_at")

        with {:ok, _updated} <-
               Ash.update(issue, %{merge_watch: lane}, action: :record_merge_watch),
             do: :ok
      else
        :ok
      end
    end
  end

  @doc "Was the ticket's PR pulled out of the merge queue (`pull/1`)?"
  @spec pulled?(Issue.t() | map() | nil) :: boolean()
  def pulled?(%{merge_watch: %{"pulled_at" => at}}) when is_binary(at), do: true
  def pulled?(_), do: false

  @doc """
  The options to start the ticket's Watchdog with, read from the row alone:
  the PR ref, its workspace and repo, and the recorded lane. The adapter is
  the one that opened the PR (it minted the ref), else the workspace's.

  `{:error, reason}` when the row has nothing to watch — no PR, or a ticket
  that has already merged or closed — or its adapter cannot be resolved, and
  `{:error, :pulled}` for a ticket pulled out of the merge queue (`pull/1`).
  """
  @spec watch_opts(Issue.t() | String.t()) :: {:ok, keyword()} | {:error, term()}
  def watch_opts(task_id) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, issue} -> watch_opts(issue)
      {:error, _} -> {:error, :not_found}
    end
  end

  def watch_opts(%Issue{} = issue) do
    lane = issue.merge_watch || %{}
    workspace = load_workspace(issue.workspace_id)

    cond do
      not present?(issue.pr_ref) ->
        {:error, :no_mr_ref}

      issue.state not in [:active, :merging] ->
        {:error, {:not_open, issue.state}}

      pulled?(issue) ->
        {:error, :pulled}

      true ->
        with {:ok, adapter} <- lane_adapter(lane, workspace) do
          {:ok, build_watch_opts(issue, lane, adapter, workspace)}
        end
    end
  end

  defp build_watch_opts(issue, lane, adapter, workspace) do
    via_review_gate =
      case Map.fetch(lane, "via_review_gate") do
        {:ok, recorded} ->
          recorded == true

        # A PR opened before its ticket recorded a lane (open when bd-741sid
        # deployed). The ReviewGate stamps the head it approves, so a stamp
        # means the gate approved this PR.
        :error ->
          present?(issue.last_reviewed_sha)
      end

    auto_merge =
      cond do
        Map.get(lane, "force_merge") == true -> true
        is_boolean(Map.get(lane, "auto_merge")) -> Map.get(lane, "auto_merge")
        true -> workspace_auto_merge?(workspace)
      end

    [
      task_id: issue.id,
      mr_ref: issue.pr_ref,
      adapter: adapter,
      workspace: workspace,
      repo: Map.get(lane, "repo") || issue.repo,
      auto_merge: auto_merge,
      via_review_gate: via_review_gate,
      local_head_sha: Map.get(lane, "local_head_sha"),
      reviewed_sha: Map.get(lane, "reviewed_sha"),
      auto_resumes: Map.get(lane, "auto_resumes")
    ]
    |> put_opt(:interval_ms, integer(lane, "interval_ms"))
    |> put_opt(:initial_delay_ms, integer(lane, "initial_delay_ms"))
    |> put_opt(:max_polls, integer(lane, "max_polls") || workspace_max_polls(workspace))
    |> put_opt(:auto_resume_dispatcher, lane_module(lane, "auto_resume_dispatcher", :resume))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The adapter recorded on the lane when it is a loaded module implementing
  # the merger behaviour — never an atom minted from the row — else the
  # workspace's configured strategy.
  defp lane_adapter(lane, workspace) do
    case lane_module(lane, "adapter", :get) do
      nil -> workspace_adapter(workspace)
      adapter -> {:ok, adapter}
    end
  end

  defp workspace_adapter(%Workspace{} = workspace) do
    {:ok, Mergers.for_workspace(workspace)}
  rescue
    _ -> {:error, :no_adapter}
  end

  defp workspace_adapter(_), do: {:error, :no_adapter}

  defp lane_module(lane, key, required_fun) do
    with name when is_binary(name) <- Map.get(lane, key),
         module when is_atom(module) <- existing_module(name),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, required_fun, 1) do
      module
    else
      _ -> nil
    end
  end

  defp existing_module("Elixir." <> _ = name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp existing_module(_), do: nil

  defp integer(lane, key) do
    case Map.get(lane, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp workspace_auto_merge?(%Workspace{} = ws), do: Workspace.auto_merge?(ws)
  defp workspace_auto_merge?(_), do: false

  defp workspace_max_polls(%Workspace{} = ws), do: Workspace.watchdog_max_polls(ws)
  defp workspace_max_polls(_), do: nil

  defp load_workspace(id) when is_binary(id) do
    case Ash.get(Workspace, id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp load_workspace(_), do: nil

  # ---- the PR's outcomes --------------------------------------------------------

  @doc """
  The ticket's PR merged. The ticket finishes the way every merge path
  finishes it — `Verification.finalize_merged/2`, so it closes or, with
  `verify_after_deploy`, parks in Verifying — and the merge is announced as
  the old worker completion was: `{:worker_done, id}` to the workspace
  MergeQueue (its post-merge primary-checkout sync) and the coordinator's
  "completed" notification.

  A review-only engagement (bd-cw3w9p) is left open for ReviewPatrol — a
  ticket stamped `review_only`, or a PR a review-only run adopted onto a
  ticket already In progress, which records it on the lane — and a ticket
  something else already finalized is left alone.
  """
  @spec merged(String.t(), keyword()) ::
          {:ok, :closed | :awaiting_verification | :engagement | :already_final}
          | {:error, term()}
  def merged(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, issue} <- Ash.get(Issue, task_id) do
      mr_ref = Keyword.get(opts, :mr_ref) || issue.pr_ref

      cond do
        issue.review_only == true or Map.get(issue.merge_watch || %{}, "review_only") == true ->
          {:ok, :engagement}

        issue.state in [:closed, :verifying] ->
          {:ok, :already_final}

        true ->
          finalize(issue, mr_ref)
      end
    end
  end

  defp finalize(issue, mr_ref) do
    case Verification.finalize_merged(issue, close_upstream: true, mr_ref: mr_ref) do
      {:ok, outcome, finalized} ->
        announce_done(finalized, mr_ref)
        broadcast(:merged, issue.id)
        {:ok, outcome}

      {:error, _} = error ->
        error
    end
  end

  defp announce_done(%Issue{issue_type: :task}, _mr_ref), do: :ok

  defp announce_done(%Issue{workspace_id: ws_id, id: id} = issue, mr_ref) when is_binary(ws_id) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, "worker:done:" <> ws_id, {:worker_done, id})

    Arbiter.Events.broadcast(ws_id, "worker_done", %{
      task_id: id,
      status: "completed",
      phase: "done"
    })

    CoordinatorNotifier.completed(snapshot(issue, mr_ref))
    :ok
  rescue
    e ->
      Logger.debug("PullRequest.announce_done/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  defp announce_done(_issue, _mr_ref), do: :ok

  @doc """
  A fix or conflict pass finished: its fix is on the PR's branch, so the
  ticket goes back to Merging (`open_pr`) and the PR is the merge path's
  again. The ticket's Watchdog watched the PR throughout; if it is gone it is
  started again from the row, unless the ticket was pulled out of the merge
  queue meanwhile (`pull/1`).

  Also how a pass that never started gives back the slot it was admitted into
  (`Arbiter.Workflows.MergeQueue.PassAdmission.with_slot/2`).

  Left alone: a ticket that is not In progress, one with no PR, and one whose
  PR was closed meanwhile (`pr_closed` — a person decides that one).
  """
  @spec back_to_merging(String.t()) :: :ok | {:error, term()}
  def back_to_merging(task_id) when is_binary(task_id) do
    with {:ok, issue} <- Ash.get(Issue, task_id),
         true <- returnable?(issue),
         {:ok, _merging} <- Issue.pr_opened(task_id, issue.pr_ref) do
      unless Watchdog.alive?(task_id), do: Watchdog.restart(task_id)
      :ok
    else
      false -> :ok
      {:error, _} = error -> error
    end
  end

  defp returnable?(%Issue{state: :active, attention_cause: nil, pr_ref: ref}), do: present?(ref)
  defp returnable?(_), do: false

  @doc """
  The ticket's PR was closed without merging: the ticket goes back to work
  with the `pr_closed` attention cause, and the coordinator is paged with an
  addressed escalation naming the PR.
  """
  @spec closed(String.t(), String.t() | nil) :: {:ok, Issue.t()} | {:error, term()}
  def closed(task_id, mr_ref) when is_binary(task_id) do
    with {:ok, issue} <- Issue.pr_closed(task_id, mr_ref) do
      escalate_closed(issue, mr_ref)
      broadcast(:closed, task_id)
      {:ok, issue}
    end
  end

  defp escalate_closed(%Issue{workspace_id: ws_id, id: id} = issue, mr_ref)
       when is_binary(ws_id) do
    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: id,
      workspace_id: ws_id,
      task_ref: id,
      subject: "PR closed: #{id} — #{mr_ref || "its PR"} was closed without merging",
      body:
        "The PR for #{id} (#{mr_ref || "unknown ref"}#{url_suffix(issue)}) was closed without " <>
          "being merged. The ticket is back In progress with attention cause `pr_closed`; " <>
          "nothing is watching a PR for it now. Decide whether to reopen the PR, dispatch a " <>
          "fresh attempt, or close the ticket."
    })

    :ok
  rescue
    e ->
      Logger.warning(
        "PullRequest: pr_closed escalation for #{id} swallowed: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate_closed(_issue, _mr_ref), do: :ok

  defp url_suffix(%Issue{merger_url: url}) when is_binary(url) and url != "", do: ", #{url}"
  defp url_suffix(_), do: ""

  @doc """
  A worker-snapshot-shaped map for the ticket's PR, for the notifiers that
  used to be handed the parked worker's snapshot.
  """
  @spec snapshot(Issue.t(), String.t() | nil) :: map()
  def snapshot(%Issue{} = issue, mr_ref \\ nil) do
    mr_ref = mr_ref || issue.pr_ref

    %{
      task_id: issue.id,
      registry_key: issue.id,
      role: nil,
      workspace_id: issue.workspace_id,
      repo: issue.repo,
      status: :completed,
      current_step: nil,
      started_at: nil,
      step_started_at: nil,
      mr_ref: mr_ref,
      merger_url: issue.merger_url,
      meta: %{result: :merged, mr_ref: mr_ref}
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # ---- encoding -------------------------------------------------------------

  defp encode_status(status) do
    status
    |> Map.take(@status_keys ++ Enum.map(@status_keys, &Atom.to_string/1))
    |> stringify()
  end

  defp decode_status(nil), do: nil

  defp decode_status(status) when is_map(status) do
    Enum.reduce(@status_keys, %{}, fn key, acc ->
      case fetch(status, key) do
        {:ok, value} -> Map.put(acc, key, decode_value(key, value))
        :error -> acc
      end
    end)
  end

  defp fetch(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, _} = found -> found
      :error -> Map.fetch(map, key)
    end
  end

  defp decode_value(key, value) when is_binary(value) do
    Enum.find(Map.get(@status_atoms, key, []), value, &(Atom.to_string(&1) == value))
  end

  defp decode_value(_key, value), do: value

  # JSON-safe, string-keyed, recursively: what the row will read back as.
  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_key(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(value), do: value

  defp to_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_key(key), do: to_string(key)

  defp broadcast(event, task_id) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, @topic, {:pull_request, event, task_id})
    :ok
  rescue
    e ->
      Logger.debug("PullRequest.broadcast/2 swallowed: #{Exception.message(e)}")
      :ok
  end
end
