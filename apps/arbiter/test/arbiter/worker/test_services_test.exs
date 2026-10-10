defmodule Arbiter.Worker.TestServicesTest do
  @moduledoc """
  bd-dmcbos (P10): `Arbiter.Worker.TestServices` and its reaper, against a
  recording stand-in for `podman`. The real-pod half (a worker container on a
  pod's `lo` against a Postgres sidecar, no host loopback) is
  `test_services_podman_test.exs` (`@moduletag :podman`).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.TestServices
  alias Arbiter.Worker.TestServices.Reaper

  @name "arb-bd-p10-1234abcd"
  @pod @name <> "-pod"

  # A runner that records every call and answers from `script`: a function of
  # the argv (after the podman path) returning `{output, status}`.
  defp runner(script \\ fn _ -> {"", 0} end) do
    test_pid = self()

    fn _cmd, args, _opts ->
      send(test_pid, {:podman, args})
      script.(args)
    end
  end

  defp calls do
    receive do
      {:podman, args} -> [args | calls()]
    after
      0 -> []
    end
  end

  defp services!(specs) do
    {:ok, services} = TestServices.resolve(specs)
    services
  end

  describe "for_repo/1" do
    test "vstim gets Postgres 16, tonic Postgres 15 plus S3, anything else nothing" do
      assert {:ok, [%{name: "postgres", image: "docker.io/library/postgres:16-alpine"} = pg]} =
               TestServices.for_repo("vstim")

      assert {"DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/vstim_test"} in pg.worker_env

      assert {:ok, [%{image: "docker.io/library/postgres:15-alpine"}, %{name: "s3"}]} =
               TestServices.for_repo("tonic")

      assert {:ok, []} = TestServices.for_repo("arbiter")
      assert {:ok, []} = TestServices.for_repo(nil)
    end

    test "config overrides the defaults, and an empty list switches one off" do
      previous = Application.get_env(:arbiter, :worker_test_services)
      on_exit(fn -> restore(:worker_test_services, previous) end)

      Application.put_env(:arbiter, :worker_test_services, %{
        "vstim" => [],
        "other" => [{:postgres, version: 17, database: "other_test"}]
      })

      assert {:ok, []} = TestServices.for_repo("vstim")

      assert {:ok, [%{image: "docker.io/library/postgres:17-alpine"}]} =
               TestServices.for_repo("other")

      assert {:ok, [_, %{name: "s3"}]} = TestServices.for_repo("tonic")
    end

    defp restore(key, nil), do: Application.delete_env(:arbiter, key)
    defp restore(key, value), do: Application.put_env(:arbiter, key, value)
  end

  describe "resolve/1" do
    test "accepts presets, preset options and a full custom map" do
      custom = %{name: "redis", image: "docker.io/library/redis:7-alpine"}

      assert {:ok, [%{name: "postgres"}, %{name: "s3"}, %{name: "redis", env: [], tmpfs: []}]} =
               TestServices.resolve([:postgres, :s3, custom])
    end

    test "refuses what would reach the podman argv unchecked" do
      for bad <- [
            %{name: "Bad Name", image: "x"},
            %{name: "ok", image: "--privileged"},
            %{name: "ok", image: "x", env: [{"1BAD", "v"}]},
            %{name: "ok", image: "x", env: [{"A", "v\0"}]},
            %{name: "ok", image: "x", command: [:atom]},
            %{name: "ok", image: "x", tmpfs: ["relative"]},
            %{image: "x"},
            :nonsense
          ] do
        assert {:error, {:bad_service, _}} = TestServices.resolve([bad]), inspect(bad)
      end

      assert {:error, {:duplicate_service, "postgres"}} =
               TestServices.resolve([:postgres, :postgres])

      assert {:error, {:bad_services, :x}} = TestServices.resolve(:x)
    end
  end

  describe "uid" do
    test "Postgres carries uid 70; s3 has none; a custom spec may set one" do
      assert %{uid: 70} = TestServices.postgres()
      refute Map.has_key?(TestServices.s3(), :uid)

      assert {:ok, [%{uid: 1000}]} =
               TestServices.resolve([%{name: "x", image: "docker.io/library/x", uid: 1000}])
    end

    test "the local podman argv is unchanged by uid" do
      argv = TestServices.service_run_argv("podman", @pod, "c", TestServices.postgres())
      refute "--user" in argv
    end
  end

  describe "the argv builders" do
    test "the pod has `lo` only and the host user, labelled with this server's pid" do
      argv = TestServices.pod_create_argv("podman", @pod)

      assert [
               "podman",
               "pod",
               "create",
               "--name",
               @pod,
               "--network",
               "none",
               "--userns",
               "keep-id" | _
             ] =
               argv

      assert "arbiter.test-services=#{System.pid()}" in argv
      refute Enum.any?(argv, &String.contains?(&1, "host"))
    end

    test "a service is hardened like the worker: read-only, no caps, tmpfs state, no host mounts" do
      [pg] = services!([{:postgres, version: 16, database: "d"}])
      argv = TestServices.service_run_argv("podman", @pod, @name, pg)

      assert ["podman", "run", "-d", "--pod", @pod, "--name", @name <> "-postgres" | _] = argv

      for flag <- ["--read-only", "--cap-drop=all", "--pull=never", "no-new-privileges"],
          do: assert(flag in argv)

      refute "-v" in argv
      refute "--volume" in argv
      refute "--network" in argv
      refute "--userns" in argv

      assert "/var/lib/postgresql/data:rw,nosuid,nodev,mode=1777" in argv
      assert "POSTGRES_DB=d" in argv

      {_, after_flags} = Enum.split_while(argv, &(&1 != "--"))
      assert ["--", "docker.io/library/postgres:16-alpine", "postgres" | _] = after_flags
    end

    test "readiness is a `podman exec` into the service, or nothing" do
      [pg] = services!([:postgres])

      assert ["podman", "exec", @name <> "-postgres", "pg_isready" | _] =
               TestServices.ready_argv("podman", @name, pg)

      assert nil == TestServices.ready_argv("podman", @name, %{pg | ready: nil})
    end

    test "the worker's env joins every service's, sorted, later ones winning" do
      env = [:postgres, :s3] |> services!() |> TestServices.worker_env()

      assert {"DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/app_test"} in env
      assert {"S3_ENDPOINT", "http://127.0.0.1:9000"} in env
      assert env == Enum.sort(env)
    end
  end

  describe "start/1" do
    test "creates the pod, starts each service, waits for readiness and returns the worker env" do
      opts = [
        name: @name,
        services: services!([:postgres, :s3]),
        podman: "podman",
        runner: runner()
      ]

      assert {:ok, %{pod: @pod, services: ["postgres", "s3"], env: env}} =
               TestServices.start(opts)

      assert {"PGHOST", "127.0.0.1"} in env

      verbs =
        calls() |> Enum.map(fn args -> Enum.take(args, 2) |> Enum.join(" ") end)

      assert verbs == [
               "image exists",
               "image exists",
               "pod create",
               "run -d",
               "exec #{@name}-postgres",
               "run -d",
               "exec #{@name}-s3"
             ]
    end

    test "a repo with no services starts nothing" do
      assert {:ok, nil} = TestServices.start(name: @name, services: [], runner: runner())
      assert [] = calls()
    end

    test "pulls an image the host does not have, unless told not to" do
      missing =
        runner(fn
          ["image", "exists" | _] -> {"", 1}
          _ -> {"", 0}
        end)

      opts = [name: @name, services: services!([:postgres]), podman: "podman", runner: missing]
      assert {:ok, _} = TestServices.start(opts)
      assert ["pull", "--quiet", "docker.io/library/postgres:16-alpine"] in calls()

      assert {:error, {:service_image_missing, "docker.io/library/postgres:16-alpine"}} =
               TestServices.start([pull: false] ++ opts)

      # Refused before any pod exists, so there is nothing to remove.
      refute Enum.any?(calls(), &(Enum.take(&1, 2) == ["pod", "rm"]))
    end

    test "a service that never becomes ready fails the start and removes the pod" do
      never_ready =
        runner(fn
          ["exec" | _] -> {"pg_isready: no response\n", 2}
          _ -> {"", 0}
        end)

      opts = [
        name: @name,
        services: services!([:postgres]),
        podman: "podman",
        runner: never_ready,
        ready_timeout_ms: 0,
        ready_interval_ms: 0
      ]

      assert {:error, {:service_not_ready, "postgres", "pg_isready: no response"}} =
               TestServices.start(opts)

      assert ["pod", "rm", "--force", "--ignore", "--time", "0", @pod] in calls()
    end

    test "a service that cannot start fails the start and removes the pod" do
      broken =
        runner(fn
          ["run" | _] -> {"Error: image not found\n", 125}
          _ -> {"", 0}
        end)

      opts = [name: @name, services: services!([:postgres]), podman: "podman", runner: broken]

      assert {:error, {{:service_start, "postgres"}, 125, "Error: image not found"}} =
               TestServices.start(opts)

      assert ["pod", "rm", "--force", "--ignore", "--time", "0", @pod] in calls()
    end

    test "a pod that cannot be created fails the start" do
      broken =
        runner(fn
          ["pod", "create" | _] -> {"boom", 125}
          _ -> {"", 0}
        end)

      assert {:error, {:pod_create, 125, "boom"}} =
               TestServices.start(
                 name: @name,
                 services: services!([:postgres]),
                 podman: "podman",
                 runner: broken
               )
    end
  end

  describe "stop/2" do
    test "removes the pod and everything in it, forcibly and idempotently" do
      assert :ok = TestServices.stop(@pod, podman: "podman", runner: runner())
      assert [["pod", "rm", "--force", "--ignore", "--time", "0", @pod]] = calls()
    end

    test "refuses a name Arbiter did not make, and nil is a no-op" do
      for bad <- ["web-pod", "arb-x", "../arb-x-pod", "arb-x pod", nil] do
        if bad == nil,
          do: assert(:ok = TestServices.stop(bad, runner: runner())),
          else: assert({:error, {:bad_pod_name, ^bad}} = TestServices.stop(bad, runner: runner()))
      end

      assert [] = calls()
    end

    test "reports a failed removal; teardown/2 logs it and returns :ok" do
      failing = runner(fn _ -> {"cannot remove", 125} end)

      assert {:error, {:podman_pod_rm_failed, 125, "cannot remove"}} =
               TestServices.stop(@pod, runner: failing)

      assert :ok =
               ExUnit.CaptureLog.with_log(fn -> TestServices.teardown(@pod, runner: failing) end)
               |> elem(0)
    end
  end

  describe "reap_orphans/1" do
    defp pods_json(pods), do: {Jason.encode!(pods), 0}

    test "removes only labelled pods whose server is gone" do
      list = [
        %{"Name" => "arb-a-1-pod", "Labels" => %{"arbiter.test-services" => "111"}},
        %{"Name" => "arb-b-2-pod", "Labels" => %{"arbiter.test-services" => "222"}},
        %{"Name" => "someone-elses", "Labels" => %{"arbiter.test-services" => "111"}},
        %{"Name" => "arb-c-3-pod", "Labels" => %{}}
      ]

      run =
        runner(fn
          ["pod", "ps" | _] -> pods_json(list)
          _ -> {"", 0}
        end)

      assert ["arb-a-1-pod"] =
               TestServices.reap_orphans(runner: run, alive?: fn pid -> pid == "222" end)

      assert ["pod", "rm", "--force", "--ignore", "--time", "0", "arb-a-1-pod"] in calls()
      refute ["pod", "rm", "--force", "--ignore", "--time", "0", "arb-b-2-pod"] in calls()
    end

    test "a live set replaces the OS-pid test: a pod is live iff its name is in it (RW12, §10.6)" do
      # On a node the pod's recorded pid is the agent's own BEAM, which is always alive:
      # it says nothing about the run. The primary's live set does.
      list = [
        %{"Name" => "arb-a-1-pod", "Labels" => %{"arbiter.test-services" => "111"}},
        %{"Name" => "arb-b-2-pod", "Labels" => %{"arbiter.test-services" => "222"}}
      ]

      run =
        runner(fn
          ["pod", "ps" | _] -> pods_json(list)
          _ -> {"", 0}
        end)

      assert ["arb-a-1-pod"] =
               TestServices.reap_orphans(
                 runner: run,
                 live_pods: ["arb-b-2-pod"],
                 alive?: fn _ -> flunk("os_alive? must not be consulted for a remote run") end
               )
    end

    test "labels scope the listing to one install on one node" do
      run =
        runner(fn
          ["pod", "ps" | _] -> pods_json([])
          _ -> {"", 0}
        end)

      TestServices.reap_orphans(
        runner: run,
        live_pods: [],
        labels: [{"arbiter.install", "inst1"}, {"arbiter.node", "n1"}]
      )

      [ps] = Enum.filter(calls(), &match?(["pod", "ps" | _], &1))
      assert "label=arbiter.install=inst1" in ps
      assert "label=arbiter.node=n1" in ps
      assert "label=arbiter.test-services" in ps
    end

    test "pod_create_argv labels the pod with the install and node when asked" do
      argv =
        TestServices.pod_create_argv("podman", @pod,
          labels: [{"arbiter.install", "inst1"}, {"arbiter.node", "n1"}]
        )

      assert "arbiter.install=inst1" in argv
      assert "arbiter.node=n1" in argv

      assert TestServices.pod_create_argv("podman", @pod) ==
               TestServices.pod_create_argv("podman", @pod, [])
    end

    test "podman missing or answering nonsense reaps nothing" do
      assert [] = TestServices.reap_orphans(runner: runner(fn _ -> {"no podman", 127} end))
      assert [] = TestServices.reap_orphans(runner: runner(fn _ -> {"not json", 0} end))
    end
  end

  describe "Reaper" do
    test "removes the pod when its owner dies, whatever the reason, and only then" do
      reaper = start_supervised!({Reaper, name: :p10_reaper, enabled: false})

      owner = spawn(fn -> receive do: (:never -> :ok) end)
      :ok = Reaper.track(owner, @pod, [runner: runner(), podman: "podman"], reaper)
      :ok = Reaper.track(owner, "arb-other-pod", [runner: runner()], reaper)

      _ = :sys.get_state(reaper)
      assert [] = calls()

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
      _ = :sys.get_state(reaper)

      removed = for ["pod", "rm", _, _, _, _, pod] <- calls(), do: pod
      assert Enum.sort(removed) == Enum.sort([@pod, "arb-other-pod"])
    end

    test "sweeps orphans at boot when enabled" do
      run =
        runner(fn
          ["pod", "ps" | _] ->
            pods_json([%{"Name" => "arb-z-9-pod", "Labels" => %{"arbiter.test-services" => "1"}}])

          _ ->
            {"", 0}
        end)

      start_supervised!(
        {Reaper, name: :p10_reaper_boot, enabled: true, runner: run, alive?: fn _ -> false end}
      )

      _ = :sys.get_state(:p10_reaper_boot)

      assert ["pod", "rm", "--force", "--ignore", "--time", "0", "arb-z-9-pod"] in calls()
    end
  end
end
