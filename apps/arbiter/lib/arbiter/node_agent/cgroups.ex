defmodule Arbiter.NodeAgent.Cgroups do
  @moduledoc """
  Which cgroup controllers the user manager has delegated (`docs/design/remote-workers.md`
  §5.5, §7.4; RW2/U8 and U10). A limit whose controller is not delegated makes
  `podman run` fail (``crun: controller `cpuset` is not available``), so the
  agent emits a limit only for a controller found here and never `--cpuset-cpus`.

  A controller is delegated when it is listed in `cgroup.controllers` **and**
  enabled in `cgroup.subtree_control` of the user manager's cgroup
  (`user.slice/user-<uid>.slice/user@<uid>.service`): a `/proc/self/cgroup` read
  is the wrong test (a login session sits under `user-<uid>.slice`, not under
  the manager). A missing manager cgroup, or cgroup v1, is nothing delegated.
  """

  @doc "The delegated controllers as a list of names (`[]` when unknown)."
  @spec delegated(keyword()) :: [String.t()]
  def delegated(opts \\ []) do
    root = Keyword.get(opts, :cgroup_root, "/sys/fs/cgroup")
    uid = Keyword.get_lazy(opts, :uid, &current_uid/0)
    dir = Path.join([root, "user.slice", "user-#{uid}.slice", "user@#{uid}.service"])

    with {:ok, available} <- File.read(Path.join(dir, "cgroup.controllers")),
         {:ok, enabled} <- File.read(Path.join(dir, "cgroup.subtree_control")) do
      MapSet.intersection(words(available), words(enabled)) |> MapSet.to_list() |> Enum.sort()
    else
      _ -> []
    end
  end

  @doc """
  The `Container.wrap/2` limit options for `limits` (`%{memory:, memory_swap:,
  cpus:}`) given the delegated controllers: `{:ok, opts, dropped}`, or
  `{:error, :memory_not_delegated}` when a memory cap is asked for and cannot be
  enforced (fail closed: the cap protects the node's owner). `dropped` names the
  limits left out because their controller is not delegated.
  """
  @spec limit_opts(map(), [String.t()]) ::
          {:ok, keyword(), [atom()]} | {:error, :memory_not_delegated}
  def limit_opts(limits, delegated) do
    wants_memory? = Map.has_key?(limits, :memory) or Map.has_key?(limits, :memory_swap)

    if wants_memory? and "memory" not in delegated do
      {:error, :memory_not_delegated}
    else
      {keep, dropped} =
        Enum.split_with(limits, fn
          {:cpus, _} -> "cpu" in delegated
          {_memory, _} -> true
        end)

      {:ok, keep, Enum.map(dropped, &elem(&1, 0))}
    end
  end

  defp words(text), do: text |> String.split() |> MapSet.new()

  defp current_uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, status) do
      uid
    else
      _ -> "0"
    end
  end
end
