defmodule Arbiter.Worker.MemoryScope.Diagnosis do
  @moduledoc """
  What `arb doctor` needs to judge OOM exposure (bd-6zuoo6, GitHub #265): is the
  per-worker memory cap in force, and what does the server's own systemd unit do
  when one of its processes is OOM-killed?

  The question the incident turned on is the second one. With the default
  `OOMPolicy=stop`, the kernel killing *any* process in `arbiter.service`'s
  cgroup made systemd stop the whole service. The cap (`Arbiter.Worker.MemoryScope`)
  moves every worker out of that cgroup; `OOMPolicy=continue` is the backstop for
  whatever still lives in it.

  The server answers for itself (rather than the CLI guessing which unit is
  "Arbiter"): it reads its own cgroup to find the service it runs in, then asks
  that unit's manager for `OOMPolicy`.
  """

  alias Arbiter.Worker.MemoryScope

  @type t :: %{String.t() => term()}

  @doc "The diagnosis as a JSON-ready map."
  @spec run(keyword()) :: t()
  def run(opts \\ []) do
    {enabled, cap, available, reason} = cap_state(opts)

    unit = service_unit(opts)

    base = %{
      "enabled" => enabled,
      "cap" => cap,
      "available" => available,
      "unavailable_reason" => reason,
      "capped" => enabled and available,
      "service_unit" => unit && unit.name,
      "service_manager" => unit && Atom.to_string(unit.manager),
      "oom_policy" => nil,
      "memory_max" => nil
    }

    case unit && unit_properties(unit, opts) do
      %{} = props -> Map.merge(base, props)
      _ -> base
    end
  end

  @doc """
  The service unit this VM runs in, from its cgroup path:
  `%{name: "arbiter.service", manager: :user | :system}`, or `nil` when it is not
  a systemd service (a shell-launched `mix phx.server`, a container).
  """
  @spec service_unit(keyword()) :: %{name: String.t(), manager: :user | :system} | nil
  def service_unit(opts \\ []) do
    contents =
      case Keyword.fetch(opts, :cgroup) do
        {:ok, text} ->
          text

        :error ->
          case File.read("/proc/self/cgroup") do
            {:ok, text} -> text
            _ -> ""
          end
      end

    with [_ | _] = lines <- String.split(contents, "\n", trim: true),
         path when is_binary(path) <- unified_path(lines),
         name when is_binary(name) <- service_name(path) do
      %{name: name, manager: if(String.contains?(path, "/user@"), do: :user, else: :system)}
    else
      _ -> nil
    end
  end

  # ---- internals -----------------------------------------------------------

  defp cap_state(opts) do
    case MemoryScope.configured_max() do
      :disabled ->
        {false, nil, false, "disabled (ARBITER_WORKER_MEMORY_MAX=off)"}

      {:ok, max} ->
        case MemoryScope.probe(max, Keyword.take(opts, [:cmd, :systemd_run, :runtime_dir])) do
          {:ok, _} -> {true, max, true, nil}
          {:error, reason} -> {true, max, false, reason}
        end
    end
  end

  defp unified_path(lines) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ":", parts: 3) do
        ["0", "", path] -> path
        _ -> nil
      end
    end)
  end

  # The innermost *.service component: `…/app.slice/arbiter.service` (and, if a
  # unit ever nests a sub-cgroup, `…/arbiter.service/worker`). The user manager
  # (`user@1000.service`) is a service too, but never the answer: a process that
  # sits directly in it is not Arbiter's unit.
  defp service_name(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reverse()
    |> Enum.find(&String.ends_with?(&1, ".service"))
    |> case do
      nil -> nil
      "user@" <> _ -> nil
      name -> name
    end
  end

  defp unit_properties(%{name: name, manager: manager}, opts) do
    manager_args = if manager == :user, do: ["--user"], else: []

    env =
      case MemoryScope.runtime_dir(opts) do
        nil -> []
        dir -> [{"XDG_RUNTIME_DIR", dir}]
      end

    ctl = Keyword.get(opts, :systemctl) || System.find_executable("systemctl")

    with ctl when is_binary(ctl) <- ctl,
         {out, 0} <-
           MemoryScope.run_cmd(
             opts,
             ctl,
             manager_args ++ ["show", name, "-p", "OOMPolicy", "-p", "MemoryMax"],
             stderr_to_stdout: true,
             env: env
           ) do
      props =
        for line <- String.split(out, "\n", trim: true),
            [k, v] <- [String.split(line, "=", parts: 2)],
            into: %{},
            do: {k, v}

      %{
        "oom_policy" => Map.get(props, "OOMPolicy"),
        "memory_max" => Map.get(props, "MemoryMax")
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
