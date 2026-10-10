defmodule Arbiter.NodeAgent.Exec do
  @moduledoc """
  Run a command in a run's container on this node (bd-9rrrgk), for the primary's
  pre-push recipe of a run placed here: the deps cache, the image and the mounts
  live on the node, and the run's agent has usually exited (and been acked, so its
  `Arbiter.NodeAgent.Run` is gone) by the time the commit gate asks.

  `Arbiter.NodeAgent.Run` hands over the options it built the agent's container
  with (`remember/2`). `run/4` rebuilds a container from them through the same
  `Arbiter.Worker.Container.wrap/2`, so the hardening is the local code: same image,
  worktree, home, config and tmp mounts, limits and (absent) network as the agent's
  session, with the command in place of the agent. What the agent's session had
  and this must not: the secrets file (provider tokens), the test-services pod and
  the primary bridges are dropped, and the container is `--rm` under a name of its
  own, removed by name afterwards whatever happened.

  The contexts live in memory only (they name no secret, but a restarted agent has
  nothing to re-run), at most #{64} runs, oldest first out. A run with no context is
  `{:error, :no_context}` and nothing is started.
  """

  use Agent

  alias Arbiter.Worker.Container

  @name __MODULE__
  @max_contexts 64
  @grace_s 15
  @max_output_bytes 256 * 1024

  @doc false
  def start_link(_opts \\ []), do: Agent.start_link(fn -> {%{}, []} end, name: @name)

  @doc "Keep the options `run`'s agent container was built with (minus its secrets)."
  @spec remember(String.t(), keyword()) :: :ok
  def remember(run, wrap_opts) when is_binary(run) and is_list(wrap_opts) do
    context =
      wrap_opts
      |> Keyword.drop([:secrets_file, :pod, :bridges, :keep, :interactive, :podman_secrets])
      |> Keyword.update(:mount_map, %{}, & &1)

    Agent.update(@name, fn {contexts, order} ->
      order = [run | List.delete(order, run)]
      {kept, dropped} = Enum.split(order, @max_contexts)
      {Map.drop(Map.put(contexts, run, context), dropped), kept}
    end)
  catch
    :exit, _ -> :ok
  end

  @doc "Forget `run`'s context."
  @spec forget(String.t()) :: :ok
  def forget(run) do
    Agent.update(@name, fn {contexts, order} ->
      {Map.delete(contexts, run), List.delete(order, run)}
    end)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Run `command` (`sh -c`) to completion in a fresh container of `run`'s shape.
  `opts` are the agent's run options (`:podman`, `:runner`). Returns
  `{output, exit_status}` (124 when `timeout_s` plus a grace elapsed; the output is
  bounded to its tail) or `{:error, :no_context | term}`.
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {String.t(), non_neg_integer()} | {:error, term()}
  def run(run, command, timeout_s, opts \\ [])
      when is_binary(run) and is_binary(command) and is_integer(timeout_s) do
    with {:ok, context} <- fetch(run) do
      name = unique_name(Keyword.fetch!(context, :name))
      wrap_opts = Keyword.put(context, :name, name)
      podman = Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"
      runner = Keyword.take(opts, [:runner])

      case Container.wrap(["sh", "-c", command], Keyword.put(wrap_opts, :podman, podman)) do
        {:ok, [exe | args]} ->
          try do
            {output, status} =
              Container.cmd(runner, exe, args,
                stderr_to_stdout: true,
                timeout: (timeout_s + @grace_s) * 1000
              )

            {tail(output), status}
          after
            _ = Container.stop(name, runner ++ [podman: podman])
          end

        {:error, reason} ->
          {:error, {:wrap_refused, reason}}
      end
    end
  end

  defp fetch(run) do
    case Agent.get(@name, fn {contexts, _} -> Map.fetch(contexts, run) end) do
      {:ok, context} -> {:ok, context}
      :error -> {:error, :no_context}
    end
  catch
    :exit, _ -> {:error, :no_context}
  end

  # `<agent container name>-x<8 hex>`: still `arb-`-prefixed (the reaper's), and
  # within the 64 characters podman names allow.
  defp unique_name(base) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    String.slice(base, 0, 64 - 11) <> "-x" <> suffix
  end

  defp tail(output) when byte_size(output) <= @max_output_bytes, do: output

  defp tail(output),
    do: binary_part(output, byte_size(output) - @max_output_bytes, @max_output_bytes)
end
