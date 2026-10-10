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
    4. `adopt_fun` (default `Arbiter.Worker.Dispatch.adopt/2`) succeeds, and the ticket's
       Worker afterwards owns the run.

  Anything else is `{:not_adopted, reason}`, and the adopt function is responsible for
  leaving nothing behind (`Arbiter.Worker.abandon_adoption/1`): the run is held again,
  uncancelled, for the collect that follows.
  """

  alias Arbiter.Nodes.Session
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  require Logger

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
  `Arbiter.Worker.Dispatch.adopt/2`) and `:adopt_timeout_ms` (passed on to it).
  """
  @spec attempt(pid(), Run.t(), keyword()) :: outcome()
  def attempt(session, %Run{} = run, opts \\ []) do
    adopt_fun = Keyword.get(opts, :adopt_fun, &Worker.Dispatch.adopt/2)

    with :ok <- switched_on(opts),
         :ok <- eligible(run),
         :ok <- Session.adoptable(session, run.id),
         {:ok, _} <- adopt_fun.(run, Keyword.take(opts, [:adopt_timeout_ms])),
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

  defp switched_on(opts) do
    if Keyword.get_lazy(opts, :adopt?, &enabled?/0), do: :ok, else: {:error, :disabled}
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
