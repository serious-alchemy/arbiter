defmodule Arbiter.Nodes.Adoption do
  @moduledoc """
  Worker adoption of a run a node kept across a primary restart (bd-4p1vui,
  `docs/design/remote-workers.md` §10.4). `Arbiter.Nodes.Recovery` asks `attempt/3`
  first for every live remote run; only a run that is not adopted is collected (the
  v1 hold-then-collect path), in the same task, so a run is adopted or collected, never
  both.

  `attempt/3` adopts when, in order:

    1. adoption is on: `config :arbiter, :node_run_adoption` is not `false` (the kill
       switch; `:adopt?` overrides it);
    2. the row is the ticket's own live run, on a node, on Claude (`eligible/1`):
       state `starting | working`, kind `implement`, role `base`;
    3. the node's session agrees (`Arbiter.Nodes.Session.adoptable/2`: the run is held, the
       agent advertises `caps["run_adopt"]` and reported it `running`, nothing is collecting
       it);
    4. `adopt_fun` (default `Arbiter.Worker.Dispatch.adopt/2`) succeeds within
       `:adopt_timeout_ms`, and the ticket's Worker afterwards owns the run.

  Anything else is `{:not_adopted, reason}`, and the adopt function is responsible for
  leaving nothing behind (`Arbiter.Worker.abandon_adoption/1`): the run is held again,
  uncancelled, for the collect that follows.

  `:adopt_timeout_ms` bounds the whole adoption, not only the node's answer: the egress
  run, the image plan and its publication come before the node is even asked (§10.4.6
  F12). An adopter cut off before its Worker's session attached the run is undone by
  `abandon_unattached/1`, so no Worker is left adopting it; one whose session attached it
  owns the run and is left to finish.
  """

  alias Arbiter.Nodes.Session
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  @type outcome :: :adopted | {:not_adopted, term()}

  @doc "Whether adoption is on: `config :arbiter, :node_run_adoption` (default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:arbiter, :node_run_adoption, true) != false

  @doc """
  Whether `run`'s row is one a new Worker may adopt: `:ok`, or `{:error, {:ineligible,
  what}}` (§10.4.4).
  """
  @spec eligible(Run.t()) :: :ok | {:error, {:ineligible, atom()}}
  def eligible(%Run{} = run) do
    cond do
      run.state not in [:starting, :working] -> {:error, {:ineligible, :state}}
      run.kind != :implement -> {:error, {:ineligible, :kind}}
      run.role not in [nil, "base"] -> {:error, {:ineligible, :role}}
      run.provider != "claude" -> {:error, {:ineligible, :provider}}
      is_nil(run.node_id) -> {:error, {:ineligible, :not_remote}}
      true -> :ok
    end
  end

  @doc """
  Try to adopt `run` through its node's `session`. Options: `:adopt?` (default
  `enabled?/0`), `:adopt_fun` (`(run, opts) -> {:ok, _} | {:error, reason}`, default
  `Arbiter.Worker.Dispatch.adopt/2`) and `:adopt_timeout_ms` (the whole adoption's
  deadline, see the moduledoc; also passed on to `adopt_fun`, for the node's answer).
  """
  @spec attempt(pid(), Run.t(), keyword()) :: outcome()
  def attempt(session, %Run{} = run, opts \\ []) do
    adopt_fun = Keyword.get(opts, :adopt_fun, &Worker.Dispatch.adopt/2)

    with :ok <- switched_on(opts),
         :ok <- eligible(run),
         :ok <- Session.adoptable(session, run.id),
         {:ok, _} <- adopt_within(adopt_fun, run, opts),
         :ok <- owned_by_worker(run) do
      :adopted
    else
      {:error, reason} -> {:not_adopted, reason}
      other -> {:not_adopted, {:unexpected, other}}
    end
  rescue
    e -> {:not_adopted, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:not_adopted, {kind, reason}}
  end

  @doc """
  What `Arbiter.Worker.Dispatch.adopt/2` hands the adopting Worker as `meta[:adopt]` and
  `ClaudeSession.start/1` as `:adopt`: the row's id, node, session, model, harness, config
  dir, start and the stdout bytes its old Worker processed.
  """
  @spec adopt_info(Run.t()) :: map()
  def adopt_info(%Run{} = run) do
    %{
      run_id: run.id,
      node_id: run.node_id,
      session_id: run.session_id,
      model: run.model,
      harness_version: run.harness_version,
      config_dir: run.config_dir,
      started_at: run.started_at,
      stdout_offset: run.stdout_offset
    }
  end

  @doc "Whether the ticket's registered Worker is the one running `run` (it was adopted)."
  @spec adopted?(Run.t()) :: boolean()
  def adopted?(%Run{} = run), do: owned_by_worker(run) == :ok

  @doc """
  Undo an adoption of `run` whose adopter was cut off (bd-4p1vui, §10.4.6 F12): if the
  ticket's Worker is still adopting `run` (no session has attached it), it gives the run
  back to its node's hold, uncancelled, and stops (`Arbiter.Worker.abandon_adoption/2`).
  `:ok` when it did, `{:error, :attached}` when the Worker owns the run (it is adopted),
  `{:error, :not_adopting}` when there is nothing to undo.
  """
  @spec abandon_unattached(Run.t()) :: :ok | {:error, :attached | :not_adopting}
  def abandon_unattached(%Run{id: id, task_id: task_id}) do
    case Worker.whereis(task_id) do
      pid when is_pid(pid) -> Worker.abandon_adoption(pid, id)
      _ -> {:error, :not_adopting}
    end
  catch
    :exit, _ -> {:error, :not_adopting}
  end

  defp switched_on(opts) do
    if Keyword.get_lazy(opts, :adopt?, &enabled?/0), do: :ok, else: {:error, :disabled}
  end

  # The adopter runs linked to this process, so it never outlives it (`Nodes.Recovery`'s
  # budget backstop kills this process, and then undoes what is left itself).
  defp adopt_within(adopt_fun, %Run{} = run, opts) do
    fun_opts = Keyword.take(opts, [:adopt_timeout_ms])
    task = Task.async(fn -> call_adopt_fun(adopt_fun, run, fun_opts) end)

    case Task.yield(task, Keyword.get(opts, :adopt_timeout_ms) || :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> cut_off(task, run)
    end
  end

  # An adopter whose Worker's session attached the run is past the point of no return: it is
  # let finish (what is left, the machine and the driver, is quick). Any other's Worker is
  # given up before the adopter is stopped, and once more after, for a Worker the adopter
  # started in between.
  defp cut_off(task, run) do
    case abandon_unattached(run) do
      {:error, :attached} ->
        Task.await(task, :infinity)

      _undone_or_nothing ->
        _ = Task.shutdown(task, :brutal_kill)

        case abandon_unattached(run) do
          {:error, :attached} -> {:ok, :attached}
          _ -> {:error, :adopt_timeout}
        end
    end
  end

  defp call_adopt_fun(adopt_fun, run, opts) do
    adopt_fun.(run, opts)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp owned_by_worker(%Run{id: id, task_id: task_id}) do
    case Worker.whereis(task_id) do
      pid when is_pid(pid) ->
        case Worker.state(pid) do
          %{run_id: ^id} -> :ok
          _ -> {:error, :not_owned}
        end

      _ ->
        {:error, :no_worker}
    end
  catch
    :exit, _ -> {:error, :no_worker}
  end
end
