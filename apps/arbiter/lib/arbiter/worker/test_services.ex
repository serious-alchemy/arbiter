defmodule Arbiter.Worker.TestServices do
  @moduledoc """
  Test services for container workers (bd-dmcbos, P10 of
  `docs/design/podman-worker-containers.md`): a per-worker **pod** holding the
  databases and object stores a repo's test suite needs, so a worker in a
  container can run `mix test` against them with no network at all.

  Optional. Arbiter itself needs no service (SQLite), and a repo with no
  definition gets no pod: `Arbiter.Worker.ContainerSpawn` runs it exactly as
  before.

  ## Why a pod

  The worker container is `--network=none`: its only exit is the egress and
  Arbiter bridge sockets (§5.1). A service has to be reachable without adding
  an exit, so it joins the worker's network namespace instead of the worker
  joining the host's:

      podman pod create --name arb-…-pod --network none --userns keep-id
      podman run -d --pod arb-…-pod --name arb-…-postgres  postgres:16-alpine …
      podman run    --pod arb-…-pod --name arb-…           <worker image> claude …

  Every member shares the pod's network namespace, whose only interface is
  `lo`, so the worker reaches Postgres on `127.0.0.1:5432` and the host's
  loopback is not there at all. That is the point of choosing this over
  `pasta:--map-host-loopback` (§5.1, rejected): that option exposes **every**
  host loopback service, Arbiter and epmd included. `podman_test.exs` proves it
  by listening on the host's loopback and failing to connect to it from the
  worker.

  ## What a service is

  A map with `:name`, `:image` and optionally `:env`, `:command`, `:tmpfs`,
  `:ready` (an argv `podman exec`ed in the service until it exits 0) and
  `:worker_env` (what the *worker* gets: `DATABASE_URL` and friends). Two
  presets cover the repos the design names:

    * `:postgres` — `docker.io/library/postgres:<version>-alpine`, user and
      password `postgres`, on `127.0.0.1:5432`; options `:version` (default
      16), `:database` (default `"app_test"`).
    * `:s3` — `docker.io/pgsty/silo` (the MinIO fork tonic's compose uses),
      credentials `minioadmin`, with the SSE-S3 test key tonic needs, on
      `127.0.0.1:9000`.

  `for_repo/1` resolves a repo's list: `config :arbiter, :worker_test_services`
  (`%{"repo" => [spec, …]}`, a spec being a preset atom, `{preset, opts}`, or a
  full service map) over the built-in defaults for vstim (Postgres 16) and
  tonic (Postgres 15 + S3). `%{"repo" => []}` switches a default off.

  ## Containment

  Services are as hardened as the worker: read-only root, no capabilities,
  `no-new-privileges`, state on tmpfs (nothing survives the pod, and nothing is
  mounted from the host). They share the pod's `lo` with the worker's `socat`
  bridges, so a service could reach Arbiter as that worker; it is a pinned
  public image the operator named, not the agent.

  Postgres runs as the host user (the pod's `keep-id`), which cannot `chmod`
  its socket directory, so its tmpfs mounts are mode 1777 and the entrypoint's
  failing `chmod` is harmless (verified against postgres 16-alpine).

  ## Teardown

  `--rm` on the worker container does not remove the pod, so the pod is its own
  lifecycle: `stop/2` (`podman pod rm --force --ignore --time 0`) removes it
  with every member, `Arbiter.Worker.ContainerSpawn.teardown/1` calls it from the
  worker's terminate path, `Arbiter.Worker.TestServices.Reaper` calls it when the
  owning worker process dies by any means (including `:kill`), and the same
  reaper removes pods whose server process is gone at boot. A pod that fails to
  start is removed before `start/1` returns.
  """

  alias Arbiter.Worker.Container

  require Logger

  @label "arbiter.test-services"
  @pod_suffix "-pod"
  @name_re ~r/\A[a-z][a-z0-9-]{0,15}\z/
  @env_re ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @stop_timeout_ms 30_000
  @step_timeout_ms 120_000
  @ready_timeout_ms 90_000
  @ready_interval_ms 500
  @flat_tmpfs "rw,nosuid,nodev,mode=1777"

  @type service :: %{
          required(:name) => String.t(),
          required(:image) => String.t(),
          optional(:env) => [{String.t(), String.t()}],
          optional(:command) => [String.t()],
          optional(:tmpfs) => [String.t()],
          optional(:ready) => [String.t()],
          optional(:worker_env) => [{String.t(), String.t()}]
        }

  @type started :: %{pod: String.t(), services: [String.t()], env: [{String.t(), String.t()}]}

  @defaults %{
    "vstim" => [{:postgres, version: 16, database: "vstim_test"}],
    "tonic" => [{:postgres, version: 15, database: "tonic_test"}, :s3]
  }

  # -- definitions ---------------------------------------------------------------

  @doc "The built-in per-repo service lists (`config :arbiter, :worker_test_services` overrides them)."
  @spec defaults() :: %{String.t() => [term()]}
  def defaults, do: @defaults

  @doc """
  The services `repo`'s tests run against: `{:ok, []}` when it has none (the
  common case), `{:ok, services}` or the first definition error.
  """
  @spec for_repo(String.t() | nil) :: {:ok, [service()]} | {:error, term()}
  def for_repo(repo) when is_binary(repo) and repo != "" do
    configured = Application.get_env(:arbiter, :worker_test_services, %{})

    case @defaults |> Map.merge(configured) |> Map.get(repo) do
      nil -> {:ok, []}
      specs -> resolve(specs)
    end
  end

  def for_repo(_), do: {:ok, []}

  @doc "Resolve spec terms (presets and custom maps) into validated services."
  @spec resolve([term()]) :: {:ok, [service()]} | {:error, term()}
  def resolve(specs) when is_list(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case spec |> expand() |> validate() do
        {:ok, service} -> {:cont, {:ok, [service | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, services} -> unique(Enum.reverse(services))
      error -> error
    end
  end

  def resolve(other), do: {:error, {:bad_services, other}}

  defp unique(services) do
    names = Enum.map(services, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> {:ok, services}
      [dup | _] -> {:error, {:duplicate_service, dup}}
    end
  end

  defp expand(:postgres), do: postgres([])
  defp expand(:s3), do: s3([])
  defp expand({:postgres, opts}) when is_list(opts), do: postgres(opts)
  defp expand({:s3, opts}) when is_list(opts), do: s3(opts)
  defp expand(%{} = service), do: service
  defp expand(other), do: {:invalid, other}

  @doc "The Postgres preset. Options: `:version` (default 16), `:database` (default `\"app_test\"`)."
  @spec postgres(keyword()) :: service()
  def postgres(opts \\ []) do
    version = Keyword.get(opts, :version, 16)
    database = Keyword.get(opts, :database, "app_test")

    %{
      name: "postgres",
      image: "docker.io/library/postgres:#{version}-alpine",
      env: [
        {"POSTGRES_USER", "postgres"},
        {"POSTGRES_PASSWORD", "postgres"},
        {"POSTGRES_DB", database},
        {"PGDATA", "/var/lib/postgresql/data/pgdata"}
      ],
      command: ["postgres", "-c", "fsync=off", "-c", "listen_addresses=127.0.0.1"],
      tmpfs: [
        "/var/lib/postgresql/data:" <> @flat_tmpfs,
        "/var/run/postgresql:" <> @flat_tmpfs
      ],
      ready: ["pg_isready", "-h", "127.0.0.1", "-p", "5432", "-U", "postgres", "-d", database],
      worker_env: [
        {"DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/#{database}"},
        {"PGHOST", "127.0.0.1"},
        {"PGPORT", "5432"},
        {"PGUSER", "postgres"},
        {"PGPASSWORD", "postgres"}
      ]
    }
  end

  @doc "The S3-compatible store preset (`pgsty/silo`, a MinIO fork). Options: `:image`."
  @spec s3(keyword()) :: service()
  def s3(opts \\ []) do
    %{
      name: "s3",
      image: Keyword.get(opts, :image, "docker.io/pgsty/silo"),
      env: [
        {"MINIO_ROOT_USER", "minioadmin"},
        {"MINIO_ROOT_PASSWORD", "minioadmin"},
        # SSE-S3 (AES256) support: without a KMS key silo answers
        # NotImplemented to the header tonic sends on every PHI-bearing PUT.
        {"MINIO_KMS_SECRET_KEY", "tonic-dev-key:DeVeLYqwANQlgD5S1i+5+EKa0Qemll5hfObx4DeRPd0="}
      ],
      command: [
        "silo",
        "server",
        "/data",
        "--address",
        "127.0.0.1:9000",
        "--console-address",
        "127.0.0.1:9001"
      ],
      tmpfs: ["/data:" <> @flat_tmpfs, "/tmp:rw,nosuid,nodev"],
      ready: ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:9000/minio/health/ready"],
      worker_env: [
        {"AWS_ACCESS_KEY_ID", "minioadmin"},
        {"AWS_SECRET_ACCESS_KEY", "minioadmin"},
        {"S3_ENDPOINT", "http://127.0.0.1:9000"}
      ]
    }
  end

  defp validate({:invalid, other}), do: {:error, {:bad_service, other}}

  defp validate(%{name: name, image: image} = service) do
    service =
      Map.merge(%{env: [], command: [], tmpfs: [], ready: nil, worker_env: []}, service)

    with true <- (is_binary(name) and Regex.match?(@name_re, name)) or {:bad_name, name},
         true <- valid_image?(image) or {:bad_image, image},
         true <- valid_pairs?(service.env) or {:bad_env, name},
         true <- valid_pairs?(service.worker_env) or {:bad_worker_env, name},
         true <- strings?(service.command) or {:bad_command, name},
         true <- service.ready == nil or strings?(service.ready) or {:bad_ready, name},
         true <- tmpfs?(service.tmpfs) or {:bad_tmpfs, name} do
      {:ok, service}
    else
      {tag, value} -> {:error, {:bad_service, {tag, value}}}
    end
  end

  defp validate(other), do: {:error, {:bad_service, other}}

  defp valid_image?(image),
    do: is_binary(image) and image != "" and not String.starts_with?(image, "-")

  defp valid_pairs?(pairs) when is_list(pairs) do
    Enum.all?(pairs, fn
      {k, v} -> is_binary(k) and Regex.match?(@env_re, k) and is_binary(v) and not nul?(v)
      _ -> false
    end)
  end

  defp valid_pairs?(_), do: false

  defp strings?(list), do: is_list(list) and Enum.all?(list, &(is_binary(&1) and not nul?(&1)))
  defp nul?(v), do: String.contains?(v, "\0")

  defp tmpfs?(list), do: strings?(list) and Enum.all?(list, &String.starts_with?(&1, "/"))

  # -- the argv builders (pure) -----------------------------------------------------

  @doc "The pod's name for the worker container `name` (`<name>-pod`)."
  @spec pod_name(String.t()) :: String.t()
  def pod_name(container_name) when is_binary(container_name),
    do: container_name <> @pod_suffix

  @doc "The service container's name (`<worker container>-<service>`)."
  @spec service_name(String.t(), service()) :: String.t()
  def service_name(container_name, %{name: name}), do: "#{container_name}-#{name}"

  @doc """
  `podman pod create`: `lo` only, and the host user mapped through as the
  worker container's own `--userns=keep-id` would (members cannot choose).
  The label carries this server's OS pid so a later boot can tell an orphan
  from a live pod (`reap_orphans/1`).
  """
  @spec pod_create_argv(String.t(), String.t()) :: [String.t()]
  def pod_create_argv(podman, pod) do
    [
      podman,
      "pod",
      "create",
      "--name",
      pod,
      "--network",
      "none",
      "--userns",
      "keep-id",
      "--label",
      "#{@label}=#{System.pid()}"
    ]
  end

  @doc "`podman run -d` for `service` as a member of `pod`."
  @spec service_run_argv(String.t(), String.t(), String.t(), service()) :: [String.t()]
  def service_run_argv(podman, pod, container_name, service) do
    Enum.concat([
      [podman, "run", "-d", "--pod", pod, "--name", service_name(container_name, service)],
      ["--pull=never", "--read-only", "--cap-drop=all", "--security-opt", "no-new-privileges"],
      Enum.flat_map(service.tmpfs, &["--tmpfs", &1]),
      Enum.flat_map(service.env, fn {k, v} -> ["-e", "#{k}=#{v}"] end),
      ["--", service.image],
      service.command
    ])
  end

  @doc """
  `podman exec` of the service's readiness check, or `nil` when it has none. No
  `--`: podman would take it for the command's name (as `run` does, `Container`).
  """
  @spec ready_argv(String.t(), String.t(), service()) :: [String.t()] | nil
  def ready_argv(_podman, _container_name, %{ready: nil}), do: nil

  def ready_argv(podman, container_name, %{ready: ready} = service),
    do: [podman, "exec", service_name(container_name, service) | ready]

  @doc "The environment the worker gets from `services` (later services win a clash)."
  @spec worker_env([service()]) :: [{String.t(), String.t()}]
  def worker_env(services) do
    services
    |> Enum.flat_map(& &1.worker_env)
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, k, v) end)
    |> Map.to_list()
    |> Enum.sort()
  end

  # -- start / stop -------------------------------------------------------------------

  @doc """
  Create the pod and start every service in it, waiting for each to report
  ready. Options: `:name` (the worker container's name; required), `:services`
  (resolved; required), `:podman` (else the host's), `:runner` (a stand-in for
  the `podman` call), `:ready_timeout_ms`, `:ready_interval_ms`, `:pull`
  (`false` to refuse a missing image instead of pulling it; default `true`).

  Returns `{:ok, %{pod, services, env}}` with `env` being what the worker needs
  (`worker_env/1`). On **any** failure the pod is removed before this returns,
  so a failed start leaves nothing behind. A service list of `[]` starts
  nothing and returns `{:ok, nil}`.
  """
  @spec start(keyword()) :: {:ok, started() | nil} | {:error, term()}
  def start(opts) do
    case Keyword.fetch!(opts, :services) do
      [] -> {:ok, nil}
      services -> start_pod(opts, services)
    end
  end

  defp start_pod(opts, services) do
    name = Keyword.fetch!(opts, :name)
    pod = pod_name(name)
    podman = podman(opts)

    with :ok <- check_pod(pod),
         :ok <- ensure_images(opts, podman, services),
         :ok <- step(opts, :pod_create, pod_create_argv(podman, pod)) do
      case run_services(opts, podman, pod, name, services) do
        :ok ->
          {:ok, %{pod: pod, services: Enum.map(services, & &1.name), env: worker_env(services)}}

        {:error, _} = error ->
          _ = stop(pod, opts)
          error
      end
    end
  end

  defp run_services(opts, podman, pod, name, services) do
    Enum.reduce_while(services, :ok, fn service, :ok ->
      with :ok <-
             step(
               opts,
               {:service_start, service.name},
               service_run_argv(podman, pod, name, service)
             ),
           :ok <- await_ready(opts, ready_argv(podman, name, service), service.name) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_images(opts, podman, services) do
    services
    |> Enum.map(& &1.image)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn image, :ok ->
      case image_present(opts, podman, image) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp image_present(opts, podman, image) do
    case call(opts, [podman, "image", "exists", image], @stop_timeout_ms) do
      {_, 0} ->
        :ok

      _ ->
        if Keyword.get(opts, :pull, true),
          do: step(opts, {:image_pull, image}, [podman, "pull", "--quiet", image]),
          else: {:error, {:service_image_missing, image}}
    end
  end

  defp await_ready(_opts, nil, _name), do: :ok

  defp await_ready(opts, argv, name) do
    timeout = Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)
    interval = Keyword.get(opts, :ready_interval_ms, @ready_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(opts, argv, name, interval, deadline)
  end

  defp poll(opts, argv, name, interval, deadline) do
    case call(opts, argv, @stop_timeout_ms) do
      {_, 0} ->
        :ok

      {out, status} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:service_not_ready, name, last_line(out, status)}}
        else
          if interval > 0, do: Process.sleep(interval)
          poll(opts, argv, name, interval, deadline)
        end
    end
  end

  defp last_line(out, status) do
    case out |> String.trim() |> String.split("\n") |> List.last() do
      line when line in [nil, ""] -> "exit #{status}"
      line -> line
    end
  end

  defp step(opts, what, [cmd | args]) do
    case Container.cmd(opts, cmd, args, timeout: @step_timeout_ms) do
      {_, 0} -> :ok
      {out, status} -> {:error, {what, status, String.trim(out)}}
    end
  end

  defp call(opts, [cmd | args], timeout),
    do: Container.cmd(opts, cmd, args, timeout: timeout)

  defp podman(opts),
    do: Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"

  @doc """
  `podman pod rm --force --ignore --time 0 <pod>`: removes the pod and every
  member whether running, stopped or already gone. Refuses a name that is not
  an `arb-…-pod` one, so teardown can never touch a pod Arbiter did not start.
  Options: `:runner`, `:podman`.
  """
  @spec stop(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def stop(pod, opts \\ [])
  def stop(nil, _opts), do: :ok

  def stop(pod, opts) do
    with :ok <- check_pod(pod) do
      args = ["pod", "rm", "--force", "--ignore", "--time", "0", pod]

      case Container.cmd(opts, podman(opts), args, timeout: @stop_timeout_ms) do
        {_, 0} -> :ok
        {out, status} -> {:error, {:podman_pod_rm_failed, status, String.trim(out)}}
      end
    end
  end

  @doc "`stop/2` that logs a failure instead of returning it. Always `:ok`."
  @spec teardown(String.t() | nil, keyword()) :: :ok
  def teardown(pod, opts \\ []) do
    case stop(pod, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("test-services pod #{pod} teardown failed: #{inspect(reason)}")
    end

    :ok
  end

  defp check_pod(pod) when is_binary(pod) do
    if String.starts_with?(pod, "arb-") and String.ends_with?(pod, @pod_suffix) and
         Regex.match?(~r/\Aarb-[a-zA-Z0-9][a-zA-Z0-9_.-]{0,80}\z/, pod),
       do: :ok,
       else: {:error, {:bad_pod_name, pod}}
  end

  defp check_pod(pod), do: {:error, {:bad_pod_name, pod}}

  # -- orphans ----------------------------------------------------------------------------

  @doc """
  Remove the pods a dead server left behind: every pod carrying this module's
  label whose recorded OS pid is no longer alive (never one of a live server,
  so a second Arbiter on the host keeps its own). Returns the names removed.
  Options: `:runner`, `:podman`, `:alive?` (`(os_pid -> boolean)`, for tests).
  """
  @spec reap_orphans(keyword()) :: [String.t()]
  def reap_orphans(opts \\ []) do
    alive? = Keyword.get(opts, :alive?, &os_alive?/1)
    args = ["pod", "ps", "--filter", "label=#{@label}", "--format", "json"]

    with {out, 0} <- Container.cmd(opts, podman(opts), args, timeout: @stop_timeout_ms),
         {:ok, pods} when is_list(pods) <- Jason.decode(out) do
      pods
      |> Enum.filter(&orphan?(&1, alive?))
      |> Enum.map(& &1["Name"])
      |> Enum.filter(&(stop(&1, opts) == :ok))
    else
      _ -> []
    end
  end

  defp orphan?(%{"Name" => name, "Labels" => %{@label => pid}}, alive?) when is_binary(name) do
    String.starts_with?(name, "arb-") and not alive?.(pid)
  end

  defp orphan?(_, _), do: false

  defp os_alive?(pid), do: pid == System.pid() or File.exists?("/proc/#{pid}")
end
