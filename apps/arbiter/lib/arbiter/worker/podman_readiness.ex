defmodule Arbiter.Worker.PodmanReadiness do
  @moduledoc """
  Is this host ready to run workers in rootless podman containers? (bd-46xndf,
  P1 of `docs/design/podman-worker-containers.md`.)

  The doctor's input (`GET /api/server/podman_sandbox`, `arb server doctor`):
  one report with a check per prerequisite the design's Appendix A probed on the
  laptop, each failure carrying a hint in the style of `Jail.explain/1`. It
  answers "can this host run the podman backend" without a spike, so an operator
  on another host (a RHEL 8 EC2 with podman 4.9, fuse-overlayfs, slirp4netns and
  cgroups v1, say) gets the answer from `arb server doctor`.

  Checks, in order: podman present and its version, rootless, storage driver,
  `/etc/subuid`/`subgid`, `user.max_user_namespaces`, SELinux mode, cgroup
  version, a rootless network helper, and a socket-bridge self-test (a host unix
  listener reached from inside a container, which is how a `--network=none`
  worker will reach Arbiter and the proxy — design §5.3).

  Every status is `"ok"`, `"warn"` (works, with a cost worth knowing) or
  `"fail"`. `ready` is true when nothing failed. All host access goes through
  the `:runner`, `:read_file` and `:user` options so tests stub the probes.
  """

  alias Arbiter.Worker.ReleaseEnv

  @min_subid_range 65_536
  @min_podman_major 4
  @default_probe_image "docker.io/library/debian:12"
  @probe_timeout_ms 60_000

  # Connects to the unix socket mounted at /proxy; `perl` ships in debian's base,
  # `socat`/`nc` cover images that lack it.
  @bridge_client ~S"""
  perl -MIO::Socket::UNIX -e 'my $s=IO::Socket::UNIX->new(Peer=>"/proxy/bridge.sock") or die "connect: $!\n"; print scalar <$s>' 2>&1 \
    || socat - UNIX-CONNECT:/proxy/bridge.sock 2>&1 \
    || nc -U /proxy/bridge.sock 2>&1
  """

  @type check :: %{
          id: String.t(),
          name: String.t(),
          status: String.t(),
          detail: String.t(),
          hint: String.t() | nil
        }

  @type report :: %{ready: boolean(), installed: boolean(), checks: [check()]}

  @doc """
  Probe the host. Options: `:runner` (`(cmd, args, opts -> {output, status})`),
  `:read_file` (`path -> {:ok, binary} | {:error, term}`), `:user`, `:image`
  (the bridge probe image; default `ARBITER_PODMAN_PROBE_IMAGE` or
  `#{@default_probe_image}`).
  """
  @spec diagnose(keyword()) :: report()
  def diagnose(opts \\ []) do
    opts = Keyword.put_new(opts, :runner, &run/3)

    case podman_version(opts) do
      {:ok, check} ->
        info = podman_info(opts)

        checks =
          [check] ++
            [
              rootless_check(info),
              storage_check(info),
              subid_check(opts),
              userns_check(opts),
              selinux_check(opts),
              cgroups_check(info),
              network_check(opts),
              bridge_check(opts)
            ]

        %{ready: not Enum.any?(checks, &(&1.status == "fail")), installed: true, checks: checks}

      {:error, check} ->
        %{ready: false, installed: false, checks: [check]}
    end
  end

  # -- podman -----------------------------------------------------------------

  defp podman_version(opts) do
    case exec(opts, "podman", ["--version"]) do
      {out, 0} ->
        version = out |> String.trim() |> String.replace_prefix("podman version ", "")

        case Integer.parse(version) do
          {major, _} when major >= @min_podman_major ->
            {:ok, check("podman", "podman", "ok", "podman #{version}")}

          _ ->
            {:error,
             check(
               "podman",
               "podman",
               "fail",
               "podman #{version} is older than #{@min_podman_major}.x",
               "Upgrade podman to #{@min_podman_major}.x or newer (RHEL 8: `sudo dnf module install container-tools`)."
             )}
        end

      _ ->
        {:error,
         check(
           "podman",
           "podman",
           "fail",
           "podman is not installed (or not on PATH)",
           "Install podman (e.g. `sudo dnf install podman` or `sudo apt install podman`); the container sandbox backend is optional."
         )}
    end
  end

  defp podman_info(opts) do
    with {out, 0} <- exec(opts, "podman", ["info", "--format", "json"]),
         {:ok, %{} = info} <- Jason.decode(out) do
      info
    else
      _ -> %{}
    end
  end

  defp rootless_check(info) do
    case get_in(info, ["host", "security", "rootless"]) do
      true ->
        check("rootless", "rootless", "ok", "podman runs rootless as this user")

      false ->
        check(
          "rootless",
          "rootless",
          "fail",
          "podman is running rootful for this user",
          "Run Arbiter as a regular user (not root) so `podman` uses a user namespace; a root-run podman is not the sandbox this design assumes."
        )

      _ ->
        check(
          "rootless",
          "rootless",
          "fail",
          "`podman info` failed or returned no data",
          "Run `podman info` as the Arbiter user and fix what it reports (often a missing XDG_RUNTIME_DIR or a broken storage dir)."
        )
    end
  end

  defp storage_check(info) do
    driver = get_in(info, ["store", "graphDriverName"])

    mount_program =
      get_in(info, ["store", "graphOptions", "overlay.mount_program", "Executable"])

    cond do
      driver == "overlay" and is_binary(mount_program) ->
        check(
          "storage_driver",
          "storage driver",
          "warn",
          "overlay via #{mount_program} (fuse-overlayfs)",
          "fuse-overlayfs copies are slower than kernel overlay; measure `_build`/`deps` copy-and-compile before relying on it (design §9 Q4). Kernel rootless overlay needs kernel 5.13+ and no `mount_program` in storage.conf."
        )

      driver == "overlay" ->
        check("storage_driver", "storage driver", "ok", "overlay (native)")

      is_binary(driver) ->
        check(
          "storage_driver",
          "storage driver",
          "fail",
          "storage driver is #{driver}",
          "Use overlay (native on kernel 5.13+, else install fuse-overlayfs); `vfs` copies every layer and is far too slow for dependency trees."
        )

      true ->
        check(
          "storage_driver",
          "storage driver",
          "fail",
          "storage driver unknown (`podman info` failed)",
          "Run `podman info` as the Arbiter user and fix what it reports."
        )
    end
  end

  # -- user namespaces ----------------------------------------------------------

  defp subid_check(opts) do
    user = Keyword.get_lazy(opts, :user, &current_user/0)

    results =
      for file <- ["/etc/subuid", "/etc/subgid"] do
        {file, subid_range(read(opts, file), user)}
      end

    bad = Enum.filter(results, fn {_f, range} -> range < @min_subid_range end)

    case bad do
      [] ->
        check(
          "subid",
          "subuid/subgid",
          "ok",
          "#{user} has #{@min_subid_range}+ ids in both files"
        )

      _ ->
        files = Enum.map_join(bad, ", ", fn {f, r} -> "#{f} (#{r})" end)

        check(
          "subid",
          "subuid/subgid",
          "fail",
          "#{user} lacks a #{@min_subid_range}-id range in #{files}",
          "Run `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 #{user}`, then `podman system migrate`."
        )
    end
  end

  defp subid_range({:ok, body}, user) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":") do
        [^user, _start, count] -> [count |> Integer.parse() |> elem_or_zero()]
        _ -> []
      end
    end)
    |> Enum.sum()
  end

  defp subid_range(_, _user), do: 0

  defp elem_or_zero({n, _}), do: n
  defp elem_or_zero(:error), do: 0

  defp userns_check(opts) do
    case read(opts, "/proc/sys/user/max_user_namespaces") do
      {:ok, body} ->
        case Integer.parse(String.trim(body)) do
          {n, _} when n > 0 ->
            check("user_namespaces", "user namespaces", "ok", "user.max_user_namespaces = #{n}")

          _ ->
            check(
              "user_namespaces",
              "user namespaces",
              "fail",
              "user.max_user_namespaces is 0 (user namespaces disabled)",
              "Set `user.max_user_namespaces` above 0: `sudo sysctl -w user.max_user_namespaces=15000` and persist it in /etc/sysctl.d/."
            )
        end

      {:error, _} ->
        check(
          "user_namespaces",
          "user namespaces",
          "fail",
          "cannot read /proc/sys/user/max_user_namespaces",
          "This kernel does not expose user namespaces; rootless podman cannot run here."
        )
    end
  end

  # -- SELinux ------------------------------------------------------------------

  defp selinux_check(opts) do
    case exec(opts, "getenforce", []) do
      {out, 0} ->
        mode = String.trim(out)

        detail =
          case mode do
            "Enforcing" ->
              "Enforcing — workers need `--security-opt label=disable` to reach host unix sockets (design §5.3)"

            other ->
              "#{other} — `label=disable` is a no-op"
          end

        check("selinux", "SELinux", "ok", detail)

      _ ->
        check("selinux", "SELinux", "ok", "not installed (no `getenforce`) — nothing to relabel")
    end
  end

  # -- cgroups / network --------------------------------------------------------

  defp cgroups_check(info) do
    case get_in(info, ["host", "cgroupVersion"]) do
      "v2" ->
        check("cgroups", "cgroups", "ok", "cgroups v2")

      "v1" ->
        check(
          "cgroups",
          "cgroups",
          "warn",
          "cgroups v1",
          "Rootless podman cannot apply cgroup resource limits (memory, cpus, pids) on cgroup v1; boot with `systemd.unified_cgroup_hierarchy=1` for cgroups v2 if you need them."
        )

      _ ->
        check(
          "cgroups",
          "cgroups",
          "warn",
          "cgroup version unknown (`podman info` failed)",
          "Run `podman info` as the Arbiter user."
        )
    end
  end

  defp network_check(opts) do
    helpers = Enum.filter(["pasta", "slirp4netns"], &has_executable?(opts, &1))

    case helpers do
      [] ->
        check(
          "network_helper",
          "rootless network",
          "warn",
          "neither pasta nor slirp4netns found",
          "Only `--network=none` containers work without one; install `passt` (pasta) or `slirp4netns` for containers that need egress."
        )

      found ->
        check("network_helper", "rootless network", "ok", Enum.join(found, ", ") <> " available")
    end
  end

  defp has_executable?(opts, name) do
    case Keyword.fetch(opts, :find_executable) do
      {:ok, fun} -> fun.(name) != nil
      :error -> System.find_executable(name) != nil
    end
  end

  # -- socket bridge ------------------------------------------------------------

  defp bridge_check(opts) do
    image =
      Keyword.get(opts, :image) || System.get_env("ARBITER_PODMAN_PROBE_IMAGE") ||
        @default_probe_image

    case exec(opts, "podman", ["image", "exists", image]) do
      {_, 0} ->
        bridge_probe(opts, image)

      _ ->
        bridge_fail(
          "probe image #{image} is not present locally",
          "Run `podman pull #{image}` (or set ARBITER_PODMAN_PROBE_IMAGE to a local image with perl, socat or nc)."
        )
    end
  end

  defp bridge_probe(opts, image) do
    dir = Path.join(System.tmp_dir!(), "arb-podman-probe-#{System.unique_integer([:positive])}")
    sock = Path.join(dir, "bridge.sock")

    try do
      File.mkdir_p!(dir)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(sock)}])

      acceptor = Task.async(fn -> accept_loop(listener) end)

      disabled = bridge_run(opts, image, dir, ["--security-opt", "label=disable"])
      default = bridge_run(opts, image, dir, [])

      :gen_tcp.close(listener)
      Task.shutdown(acceptor, :brutal_kill)

      bridge_result(disabled, default)
    rescue
      e -> bridge_fail("self-test could not run: #{Exception.message(e)}", nil)
    after
      File.rm_rf(dir)
    end
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, conn} ->
        :gen_tcp.send(conn, "pong\n")
        :gen_tcp.close(conn)
        accept_loop(listener)

      _ ->
        :ok
    end
  end

  defp bridge_run(opts, image, dir, label_args) do
    args =
      ["run", "--rm", "--init", "--userns=keep-id", "--network=none"] ++
        label_args ++ ["-v", "#{dir}:/proxy", image, "sh", "-c", @bridge_client]

    case exec(opts, "podman", args, timeout: @probe_timeout_ms) do
      {out, 0} -> if String.contains?(out, "pong"), do: :ok, else: {:error, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp bridge_result(:ok, :ok) do
    check(
      "socket_bridge",
      "socket bridge",
      "ok",
      "host unix listener reachable from a container (also with the default SELinux label)"
    )
  end

  defp bridge_result(:ok, {:error, _}) do
    check(
      "socket_bridge",
      "socket bridge",
      "ok",
      "host unix listener reachable with `--security-opt label=disable` (the default label is denied, as expected under SELinux)"
    )
  end

  defp bridge_result({:error, out}, _default) do
    bridge_fail(
      "container could not reach a host unix listener even with label=disable: #{String.slice(out, 0, 200)}",
      "A confined container_t cannot connect() to an unconfined host listener; label=disable should lift that. If it still fails, check the probe image has perl, socat or nc, that the socket dir is writable and that `podman run` works at all."
    )
  end

  defp bridge_fail(detail, hint),
    do: check("socket_bridge", "socket bridge", "fail", detail, hint)

  # -- plumbing -----------------------------------------------------------------

  defp check(id, name, status, detail, hint \\ nil),
    do: %{id: id, name: name, status: status, detail: detail, hint: hint}

  defp exec(opts, cmd, args, run_opts \\ []) do
    Keyword.fetch!(opts, :runner).(cmd, args, run_opts)
  rescue
    e -> {Exception.message(e), 127}
  end

  defp read(opts, path), do: Keyword.get(opts, :read_file, &File.read/1).(path)

  defp current_user, do: System.get_env("USER") || System.get_env("LOGNAME") || ""

  defp run(cmd, args, opts) do
    case System.find_executable(cmd) do
      nil ->
        {"#{cmd}: not found", 127}

      path ->
        timeout = Keyword.get(opts, :timeout, 15_000)
        task = Task.async(fn -> ReleaseEnv.cmd(path, args, stderr_to_stdout: true) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {"#{cmd} timed out after #{timeout} ms", 124}
        end
    end
  end
end
