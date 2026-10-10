defmodule Arbiter.Worker.Registry do
  @moduledoc """
  Thin wrapper exposing the `:via` tuple used to register `Arbiter.Worker`
  GenServers by their task_id.

  The underlying registry is started by `Arbiter.Application` under the name
  `#{__MODULE__}`. Callers should prefer `via_tuple/1` over hand-rolling
  `{:via, Registry, ...}` tuples.
  """

  @doc """
  Return the `:via` tuple a `Arbiter.Worker` GenServer registers under for
  the given `task_id`.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(task_id) when is_binary(task_id) do
    {:via, Registry, {__MODULE__, task_id}}
  end

  @doc """
  Look up the pid of the worker registered for `task_id`, or `nil` if none.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(task_id) when is_binary(task_id) do
    case Registry.lookup(__MODULE__, task_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Return every `{registry_key, pid}` pair currently registered, regardless
  of key shape. Used by teardown paths that need to sweep synthetic
  sub-worker keys (`<task_id>:fixpass`, `<task_id>#review`, ...) rather than
  looking up a single exact key.
  """
  @spec all() :: [{String.t(), pid()}]
  def all do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Record the dispatch context of the calling worker on its own registry entry:
  the workspace it is running for and the provider it was dispatched with.

  Called by `Arbiter.Worker.init/1`. The registry value — not a counter
  anywhere — is what makes `Arbiter.Accounts.Concurrency.live_count/1`
  authoritative (`docs/provider-account-design.md` §4.2): it exists exactly as
  long as the process does, so a crashed or killed worker releases its slot
  with no decrement call on any path.

  `released: true` (bd-cut6uv) marks a worker that is parked on a machine with no
  agent of its own — its ReviewGate is waiting for CI before it dispatches a
  reviewer. `Arbiter.Accounts.Concurrency` does not count it while it is set, so
  the account is free for other work; the worker clears it again
  (`released: false`, the default) when the wait ends.

  `node_id:` (RW8, `Arbiter.Nodes.Placement`) names the remote node the run was
  placed on; `nil` (the default) is the primary. `Arbiter.Nodes.LocalCapacity`
  counts only the runs with no node against the primary's own cap.

  Must be called *from* the registered process; `Registry.update_value/3` only
  lets an owner rewrite its own value. A non-owner (or an unregistered key) is
  a no-op rather than an error — the dispatch context is an optimisation for
  the ceiling, never something a worker's boot should die on.
  """
  @spec put_dispatch(String.t(), String.t() | nil, atom() | String.t() | nil, keyword()) :: :ok
  def put_dispatch(registry_key, workspace_id, provider, opts \\ [])
      when is_binary(registry_key) do
    Registry.update_value(__MODULE__, registry_key, fn prior ->
      # A rewrite (the hold flag flipping) keeps the node `put_node/2` stamped.
      node_id =
        case {Keyword.fetch(opts, :node_id), prior} do
          {{:ok, id}, _} -> id
          {:error, %{node_id: id}} -> id
          _ -> nil
        end

      %{
        workspace_id: workspace_id,
        provider: normalize_provider(provider),
        released: Keyword.get(opts, :released, false),
        node_id: node_id
      }
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Stamp the node the calling worker's run was placed on onto its own registry
  entry (bd-8ikgoc). A worker registers at `init/1` before any node is known —
  the placement only exists once its port opens — so without this every run on
  a remote node would read as a primary run to `Arbiter.Nodes.LocalCapacity`.
  `nil` is the primary. Must be called from the registered process; a no-op
  otherwise or when `put_dispatch/4` has not run yet.
  """
  @spec put_node(String.t(), String.t() | nil) :: :ok
  def put_node(registry_key, node_id) when is_binary(registry_key) do
    Registry.update_value(__MODULE__, registry_key, fn
      %{} = value -> Map.put(value, :node_id, node_id)
      other -> other
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp normalize_provider(provider) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  defp normalize_provider(provider) when is_binary(provider) and provider != "", do: provider
  defp normalize_provider(_), do: nil

  @doc """
  Every **live** registry entry that recorded a dispatch context via
  `put_dispatch/3`, as `%{registry_key:, pid:, workspace_id:, provider:, released:, node_id:}`.

  Entries whose process has already died are dropped here rather than by the
  caller: Registry's monitor-based cleanup is asynchronous, so a killed worker
  can leave a corpse row behind for a short window and a corpse holds no slot
  (same rule as `live_for/1`).
  """
  @spec live_dispatches() :: [
          %{
            registry_key: String.t(),
            pid: pid(),
            workspace_id: String.t() | nil,
            provider: String.t() | nil,
            released: boolean(),
            node_id: String.t() | nil
          }
        ]
  def live_dispatches do
    __MODULE__
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn
      {key, pid, %{workspace_id: ws_id, provider: provider} = value} ->
        if Process.alive?(pid) do
          [
            %{
              registry_key: key,
              pid: pid,
              workspace_id: ws_id,
              provider: provider,
              released: Map.get(value, :released, false),
              node_id: Map.get(value, :node_id)
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  @doc """
  Return every `{registry_key, pid}` pair owned by `task_id`: the exact key
  itself plus synthetic sub-worker keys (`<task_id>:fixpass`,
  `<task_id>:conflict`, `<task_id>#review`, `<task_id>#r<N>`, ...).

  Ownership requires the separator (`:` or `#`) immediately after the prefix —
  rather than a bare `String.starts_with?/2` on `task_id` alone — so an
  unrelated task whose id happens to be a string-prefix of another
  (e.g. "bd-1" vs "bd-12:fixpass") never matches.

  This is the single definition of "which workers belong to this task" shared
  by the `:close` teardown hooks (`StopWorker`, `CleanupWorktree`); keeping
  them on one predicate is what lets CleanupWorktree's liveness re-check
  (bd-bmmj4w) trust that anything StopWorker was responsible for stopping is
  also something it will refuse to delete a worktree under.
  """
  @spec all_for(String.t()) :: [{String.t(), pid()}]
  def all_for(task_id) when is_binary(task_id) do
    Enum.filter(all(), fn {registry_key, _pid} -> owned_by?(registry_key, task_id) end)
  end

  @doc """
  Like `all_for/1`, but drops entries whose process is already dead.

  Registry's monitor-based cleanup is asynchronous, so a worker that died
  without its `terminate/2` running (a crash, a kill) can leave a corpse row
  behind for a short window. A corpse owns nothing and must not block
  teardown, so every "is anyone still using this task's worktree?" check
  (`CleanupWorktree`'s drain, the Driver's post-workflow reap) filters on
  `Process.alive?/1` through here rather than reading `all_for/1` raw.
  """
  @spec live_for(String.t()) :: [{String.t(), pid()}]
  def live_for(task_id) when is_binary(task_id) do
    task_id
    |> all_for()
    |> Enum.filter(fn {_registry_key, pid} -> Process.alive?(pid) end)
  end

  @doc """
  Like `live_for/1`, but only the **exclusive** family: the task's own key plus
  the merge-queue subordinate keys that use the `:` separator
  (`<task_id>:fixpass`, `<task_id>:conflict`).

  The `#` family (`<task_id>#review`, `<task_id>#impl<N>`, ...) is deliberately
  excluded. Those are `Arbiter.Worker.ReviewGate` sessions: they run in their
  own throwaway checkout, are serialised by the gate itself, and are *supposed*
  to run while the author's worker is parked — so they are not candidates for
  the single-active-worker rule enforced in `Arbiter.Worker.start/1` (bd-8tjcms).
  """
  @spec live_exclusive_for(String.t()) :: [{String.t(), pid()}]
  def live_exclusive_for(task_id) when is_binary(task_id) do
    task_id
    |> live_for()
    |> Enum.filter(fn {registry_key, _pid} -> exclusive_key?(registry_key, task_id) end)
  end

  @doc """
  True when `registry_key` belongs to `task_id`'s exclusive family — see
  `live_exclusive_for/1`.
  """
  @spec exclusive_key?(String.t(), String.t()) :: boolean()
  def exclusive_key?(registry_key, task_id) when is_binary(registry_key) and is_binary(task_id) do
    registry_key == task_id or String.starts_with?(registry_key, task_id <> ":")
  end

  def exclusive_key?(_registry_key, _task_id), do: false

  @doc """
  True when `registry_key` is owned by `task_id` — the task's own key or one
  of its synthetic sub-worker keys (`:` or `#` separated). The predicate
  behind `all_for/1`.
  """
  @spec owned_by?(String.t(), String.t()) :: boolean()
  def owned_by?(registry_key, task_id) when is_binary(registry_key) and is_binary(task_id) do
    registry_key == task_id or
      String.starts_with?(registry_key, task_id <> ":") or
      String.starts_with?(registry_key, task_id <> "#")
  end

  def owned_by?(_registry_key, _task_id), do: false

  @doc """
  Explicitly remove this process's registration. Called from the worker's
  `terminate/2` callback so callers observe `whereis/1 == nil` synchronously
  after `GenServer.stop/1` returns, rather than waiting on Registry's async
  monitor cleanup.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(task_id) when is_binary(task_id) do
    Registry.unregister(__MODULE__, task_id)
    :ok
  end
end
