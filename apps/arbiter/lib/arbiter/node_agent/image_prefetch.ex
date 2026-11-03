defmodule Arbiter.NodeAgent.ImagePrefetch do
  @moduledoc """
  SI7 (`docs/design/remote-workers.md` §21.2.4, §21.9): the agent's side of
  `image.prefetch{ref, cli_set, pull_auth, insecure}`.

  After a publish the primary tells each machine node that could take the repo's runs
  which digest is new. This process queues the refs and pulls them **in the background,
  one at a time** (a pull is 0.5–1 GB; two at once would only fight for the disk and the
  link), through the same authfile-on-tmpfs pull a run uses (`ImagePull.prefetch/5`). A
  prefetch never blocks, delays or refuses a run: it is a plain GenServer beside the
  connection, and a run that needs the image meanwhile runs its own pull.

  A ref already queued or being pulled is not queued twice, the queue is bounded
  (16 refs, the oldest dropped), and a failed pull is logged without the credential
  and forgotten: the next run pulls for itself. The payload is validated like a spec's
  `image.ref` and `pull_auth` (a digest-pinned ref; a credential for the ref's own host
  only); anything else is ignored.

  Options: `:config`, `:name`, `:pull_fun` (`(ref, image, auth, run, opts -> :ok |
  {:error, term})`, default `ImagePull.prefetch/5`), `:pull_opts` (`ImagePull`'s).
  """

  use GenServer

  alias Arbiter.NodeAgent.{ImagePull, PullAuth}

  require Logger

  @max_queue 16
  @digest_ref_re ~r/\A[a-z0-9][a-z0-9.:_\/-]{0,200}@sha256:[0-9a-f]{64}\z/

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  @doc """
  Queue a prefetch (the `image.prefetch` payload). `:ok` when queued or already known,
  `{:error, :bad_payload}` for a payload the agent will not act on, and `:ok` too when no
  prefetch process runs (an agent without one just does not warm).
  """
  @spec enqueue(map(), keyword()) :: :ok | {:error, :bad_payload}
  def enqueue(payload, opts \\ []) do
    case parse(payload) do
      {:ok, job} -> GenServer.cast(name(opts), {:enqueue, job})
      :error -> {:error, :bad_payload}
    end
  end

  @doc "`%{pulling: ref | nil, queued: [ref]}`, for tests and diagnostics."
  @spec status(keyword()) :: %{pulling: String.t() | nil, queued: [String.t()]}
  def status(opts \\ []), do: GenServer.call(name(opts), :status)

  @doc false
  @spec parse(term()) :: {:ok, map()} | :error
  def parse(%{"ref" => ref} = payload) when is_binary(ref) do
    with true <- Regex.match?(@digest_ref_re, ref),
         {:ok, auth} <- auth(payload["pull_auth"], ref) do
      {:ok, %{ref: ref, auth: auth, insecure?: payload["insecure"] == true}}
    else
      _ -> :error
    end
  end

  def parse(_payload), do: :error

  defp auth(nil, _ref), do: {:ok, nil}

  defp auth(%{"registry" => host, "username" => user, "password" => pass}, ref)
       when is_binary(host) and is_binary(user) and is_binary(pass) and user != "" and
              pass != "" do
    if host == ref |> String.split("/", parts: 2) |> hd(),
      do: {:ok, %PullAuth{registry: host, username: user, password: pass}},
      else: :error
  end

  defp auth(_other, _ref), do: :error

  # -- server -----------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       opts: opts,
       queue: :queue.new(),
       current: nil,
       seq: 0
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    current = state.current && elem(state.current, 1).ref
    {:reply, %{pulling: current, queued: Enum.map(:queue.to_list(state.queue), & &1.ref)}, state}
  end

  @impl true
  def handle_cast({:enqueue, job}, state) do
    if known?(state, job.ref) do
      {:noreply, state}
    else
      {:noreply, state |> push(job) |> next()}
    end
  end

  @impl true
  def handle_info({ref, result}, %{current: {ref, job}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finished(job, result) |> next()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: {ref, job}} = state),
    do: {:noreply, state |> finished(job, {:error, {:crashed, reason}}) |> next()}

  def handle_info(_other, state), do: {:noreply, state}

  defp known?(state, ref) do
    current? =
      case state.current do
        {_, job} -> job.ref == ref
        nil -> false
      end

    current? or Enum.any?(:queue.to_list(state.queue), &(&1.ref == ref))
  end

  defp push(state, job) do
    queue = :queue.in(job, state.queue)
    queue = if :queue.len(queue) > @max_queue, do: :queue.drop(queue), else: queue
    %{state | queue: queue}
  end

  defp next(%{current: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, job}, rest} ->
        seq = state.seq + 1
        task = Task.async(fn -> pull(job, seq, state.opts) end)
        %{state | queue: rest, current: {task.ref, job}, seq: seq}

      {:empty, _} ->
        state
    end
  end

  defp next(state), do: state

  defp pull(job, seq, opts) do
    fun = Keyword.get(opts, :pull_fun, &ImagePull.prefetch/5)
    pull_opts = Keyword.get(opts, :pull_opts, [])
    fun.(job.ref, %{insecure?: job.insecure?}, job.auth, "prefetch-#{seq}", pull_opts)
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  end

  defp finished(state, job, :ok) do
    Logger.info("node agent: prefetched #{job.ref}")
    %{state | current: nil}
  end

  defp finished(state, job, {:error, reason}) do
    Logger.warning(
      "node agent: prefetch of #{job.ref} failed: " <>
        inspect(PullAuth.redact(inspect(reason, limit: 8), job.auth))
    )

    %{state | current: nil}
  end

  defp finished(state, _job, _other), do: %{state | current: nil}

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
