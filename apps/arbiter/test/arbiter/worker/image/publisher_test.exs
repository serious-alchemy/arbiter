defmodule Arbiter.Worker.Image.PublisherTest do
  @moduledoc """
  K8 (bd-9vrbx7): `Image.Publisher` builds and pushes the worker (toolchain +
  CLI + seed layers) and controller images to `nodes.registry` and returns
  digest-pinned references. Every podman call goes through `:runner`, so this
  runs without podman or a registry.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.Image.Publisher

  @password "hunter2-NEVER-LOGGED"
  @lock String.duplicate("c", 64)

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    builder = start_supervised!({Builder, name: nil})
    server = start_supervised!({Publisher, name: nil, boot: false})

    claude = Path.join(tmp, "claude")
    arb = Path.join(tmp, "arb")
    File.write!(claude, "claude-binary")
    File.write!(arb, "arb-binary")

    cache = Path.join(tmp, "cache")
    for dir <- ["deps", "_build", "mix_home"], do: File.mkdir_p!(Path.join(cache, dir))
    File.write!(Path.join(cache, "deps/dep.txt"), "x")
    File.write!(Path.join(cache, ".complete"), "")

    plan = %{
      tag: "localhost/arbiter-dev/generated-x:abc123def456",
      name: "generated-x",
      hash: "abc123def456",
      containerfile: "FROM scratch",
      build_args: [],
      base: %{
        tag: "localhost/arbiter-dev/base:bbbbbbbbbbbb",
        name: "base",
        hash: "bbbbbbbbbbbb",
        containerfile: "FROM scratch"
      }
    }

    config = %{
      registry: "registry.example.com/arbiter",
      username: "bot",
      password: @password,
      insecure?: false
    }

    opts = [
      server: server,
      builder: builder,
      config: config,
      runner: runner(self()),
      scratch: Path.join(tmp, "scratch"),
      cli: [{claude, "/opt/arbiter/cli/claude"}, {arb, "/opt/arbiter/cli/arb"}],
      deps_ensure: fn _repo, _base, _tag, _opts ->
        {:ok, %{dir: cache, seeded?: false, lock_hash: @lock}}
      end,
      resolver: fn _ref -> {:ok, "sha256:" <> String.duplicate("d", 64)} end
    ]

    ctx = %{plan: plan, repo_path: "/repo", base: "main", seed_paths: nil}
    {:ok, opts: opts, ctx: ctx, server: server, tmp: tmp, cache: cache}
  end

  # A fake podman. Records each call; `push` writes the digest podman would.
  defp runner(test, overrides \\ %{}) do
    fn "podman", args, _opts ->
      send(test, {:podman, args})

      case Map.get(overrides, hd(args)) do
        fun when is_function(fun, 1) -> fun.(args)
        nil -> fake(test, args)
      end
    end
  end

  defp fake(test, ["image", "exists" | _]), do: send(test, :exists) && {"", 0}

  defp fake(test, ["build" | _] = args) do
    file = flag(args, "--file")
    tag = flag(args, "--tag")
    context = List.last(args)

    send(
      test,
      {:build, tag, File.read!(file), File.ls!(context) |> Enum.sort(), cli_files(context)}
    )

    {"", 0}
  end

  defp fake(test, ["push" | _] = args) do
    remote = List.last(args)
    auth = flag(args, "--authfile")
    if auth, do: send(test, {:authfile, File.read!(auth), file_mode(auth)})
    File.write!(flag(args, "--digestfile"), "sha256:" <> digest_for(remote))
    send(test, {:push, remote})
    {"Writing manifest", 0}
  end

  defp fake(_test, _args), do: {"", 0}

  defp digest_for(remote),
    do: :crypto.hash(:sha256, remote) |> Base.encode16(case: :lower)

  defp flag(args, name) do
    case Enum.find_index(args, &(&1 == name)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  defp file_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp cli_files(context) do
    case File.ls(Path.join(context, "cli")) do
      {:ok, files} -> Enum.sort(files)
      _ -> []
    end
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "ensure_ready/2 with the full image" do
    test "pushes toolchain, CLI and seed layers and returns the seed layer, digest-pinned",
         %{opts: opts, ctx: ctx} do
      assert {:ok, result} = Publisher.ensure_ready(ctx, opts)

      expected_digest = digest_for(result.tag_ref)
      assert result.ref == "registry.example.com/arbiter/worker@sha256:" <> expected_digest
      assert Arbiter.Worker.Image.Registry.digest_pinned?(result.ref)

      assert [:toolchain, :cli, :seed] = Enum.map(result.layers, & &1.layer)
      assert Enum.all?(result.layers, &Arbiter.Worker.Image.Registry.digest_pinned?(&1.ref))

      pushes = for {:push, remote} <- drain(), do: remote

      assert [
               "registry.example.com/arbiter/worker:abc123def456",
               "registry.example.com/arbiter/worker:abc123def456-cli" <> cli_rest,
               "registry.example.com/arbiter/worker:abc123def456-cli" <> seed_rest
             ] = pushes

      assert cli_rest =~ ~r/\A[0-9a-f]{8}\z/
      assert seed_rest =~ ~r/\A[0-9a-f]{8}-seed#{String.slice(@lock, 0, 12)}-[0-9a-f]{8}\z/
    end

    test "the CLI layer ships claude and arb; the seed layer ships DepsCache output",
         %{opts: opts, ctx: ctx} do
      assert {:ok, _} = Publisher.ensure_ready(ctx, opts)
      builds = for {:build, _, _, _, _} = b <- drain(), do: b

      assert {:build, _, cli_cf, _ctx_entries, ["arb", "claude"]} =
               Enum.find(builds, fn {:build, _, cf, _, _} -> cf =~ "/opt/arbiter/cli" end)

      assert cli_cf =~ "FROM localhost/arbiter-dev/generated-x:abc123def456"
      assert cli_cf =~ "COPY cli/ /opt/arbiter/cli/"

      assert {:build, _, seed_cf, entries, _} =
               Enum.find(builds, fn {:build, _, cf, _, _} -> cf =~ "/opt/arbiter/seed" end)

      assert seed_cf =~ "COPY deps/ /opt/arbiter/seed/deps/"
      assert seed_cf =~ "COPY _build/ /opt/arbiter/seed/_build/"
      assert seed_cf =~ "COPY mix_home/ /opt/arbiter/seed/mix_home/"
      assert "deps" in entries
    end

    test "credentials travel by 0600 auth file only: never argv, and the file is gone after",
         %{opts: opts, ctx: ctx} do
      assert {:ok, _} = Publisher.ensure_ready(ctx, opts)
      msgs = drain()

      for {:podman, args} <- msgs do
        refute Enum.any?(args, &(&1 =~ @password))
        refute "--creds" in args
      end

      assert {:authfile, body, 0o600} = Enum.find(msgs, &match?({:authfile, _, _}, &1))
      assert %{"auths" => %{"registry.example.com" => _}} = Jason.decode!(body)
      refute Enum.any?(Path.wildcard(Path.join(opts[:scratch], "registry-auth-*")))
    end

    test "seed_paths outside deps/_build are excluded (K26) and reported", %{opts: opts, ctx: ctx} do
      ctx = %{ctx | seed_paths: ["deps", "priv/plts", "../escape"]}
      assert {:ok, result} = Publisher.ensure_ready(ctx, opts)

      assert result.seed.status == :pushed
      assert result.seed.excluded == ["priv/plts", "../escape"]

      builds = for {:build, _, cf, _, _} <- drain(), cf =~ "/opt/arbiter/seed", do: cf
      assert [seed_cf] = builds
      assert seed_cf =~ "COPY deps/"
      refute seed_cf =~ "_build"
      refute seed_cf =~ "plts"
    end

    test "seed_paths: [] ships no seed layer; the run image is the CLI layer",
         %{opts: opts, ctx: ctx} do
      assert {:ok, result} = Publisher.ensure_ready(%{ctx | seed_paths: []}, opts)
      assert [:toolchain, :cli] = Enum.map(result.layers, & &1.layer)
      assert result.seed.status == :skipped
      assert List.last(result.layers).ref == result.ref
    end

    test "a seed layer that cannot be built is best-effort: the CLI layer still publishes",
         %{opts: opts, ctx: ctx} do
      opts = Keyword.put(opts, :deps_ensure, fn _, _, _, _ -> {:error, :no_lockfile} end)
      assert {:ok, result} = Publisher.ensure_ready(ctx, opts)
      assert [:toolchain, :cli] = Enum.map(result.layers, & &1.layer)
      assert result.seed == %{status: :skipped, reason: ":no_lockfile", excluded: []}
    end

    test "a failed push is an error whose text never carries the password",
         %{opts: opts, ctx: ctx} do
      failing =
        runner(self(), %{
          "push" => fn _ -> {"unauthorized: bad password #{@password}", 1} end
        })

      assert {:error, {:push_failed, remote, 1, tail}} =
               Publisher.ensure_ready(ctx, Keyword.put(opts, :runner, failing))

      assert remote =~ "registry.example.com/arbiter/worker:"
      refute tail =~ @password
      assert tail =~ "unauthorized"
    end

    test "an insecure registry pushes with --tls-verify=false", %{opts: opts, ctx: ctx} do
      config = Map.put(opts[:config], :insecure?, true)
      assert {:ok, _} = Publisher.ensure_ready(ctx, Keyword.put(opts, :config, config))
      push = Enum.find(drain(), &match?({:podman, ["push" | _]}, &1))
      assert {:podman, args} = push
      assert "--tls-verify=false" in args
    end
  end

  describe "ensure_ready/2 when nodes.registry is unset" do
    test ":disabled, and podman is never called", %{opts: opts, ctx: ctx} do
      opts = Keyword.put(opts, :config, %{registry: nil})
      assert Publisher.ensure_ready(ctx, opts) == :disabled
      refute_received {:podman, _}
    end
  end

  describe "ensure_ready/2 timeout and fallback" do
    test "times out cleanly, keeps the publish going, and the next call gets its result",
         %{opts: opts, ctx: ctx} do
      test = self()

      slow =
        runner(test, %{
          "push" => fn args ->
            send(test, {:push_blocked, self()})
            receive do: (:release -> :ok)
            remote = List.last(args)
            File.write!(flag(args, "--digestfile"), "sha256:" <> digest_for(remote))
            {"", 0}
          end
        })

      opts = Keyword.put(opts, :runner, slow)

      assert {:error, {:timeout, 50}} = Publisher.ensure_ready(ctx, [{:timeout_ms, 50} | opts])
      assert_receive {:push_blocked, blocked}

      # A second caller joins the same flight instead of starting another one.
      second = Task.async(fn -> Publisher.ensure_ready(ctx, [{:timeout_ms, 5_000} | opts]) end)
      send(blocked, :release)
      # The toolchain push is released; later pushes in the flight block likewise.
      release_all()

      assert {:ok, %{ref: ref}} = Task.await(second, 5_000)
      assert Arbiter.Worker.Image.Registry.digest_pinned?(ref)

      # Cached now: no podman at all.
      drain()
      assert {:ok, %{ref: ^ref}} = Publisher.ensure_ready(ctx, opts)
      refute_received {:podman, _}
    end

    test "fallback/2 follows worker.placement" do
      assert Publisher.fallback(:prefer_remote, {:timeout, 5}) == {:local, {:timeout, 5}}
      assert Publisher.fallback(:remote_only, {:timeout, 5}) == {:hold, {:timeout, 5}}
      assert Publisher.fallback(:local_only, :x) == {:local, :x}
    end
  end

  describe "publish_controller/1" do
    test "builds from the retained release tarball and pushes tag = version",
         %{opts: opts, tmp: tmp} do
      tarball = Path.join(tmp, "0.9.1.tar.gz")
      File.write!(tarball, "tarball-bytes")
      opts = Keyword.put(opts, :artifact, {:ok, %{version: "0.9.1", path: tarball}})

      assert {:ok, result} = Publisher.publish_controller(opts)

      assert result.ref ==
               "registry.example.com/arbiter/controller@sha256:" <>
                 digest_for("registry.example.com/arbiter/controller:0.9.1")

      assert {:build, _, cf, entries, _} = Enum.find(drain(), &match?({:build, _, _, _, _}, &1))
      assert entries == ["release.tar.gz"]
      assert cf =~ ~r/^FROM docker\.io\/library\/debian:trixie-slim@sha256:d{64}$/m
      assert cf =~ "ADD release.tar.gz /opt/"
      assert cf =~ "USER 10001"
      assert cf =~ ~s(ENTRYPOINT ["/opt/arbiter/bin/arbiter", "start"])
    end

    test "no retained release is an error, not a crash", %{opts: opts} do
      opts = Keyword.put(opts, :artifact, {:error, :unavailable})
      assert {:error, {:no_release, :unavailable}} = Publisher.publish_controller(opts)
    end

    test ":disabled with no registry", %{opts: opts} do
      assert Publisher.publish_controller(Keyword.put(opts, :config, %{registry: nil})) ==
               :disabled
    end
  end

  describe "status/1" do
    test "unset registry reports configured: false and probes nothing" do
      assert %{configured: false} = Publisher.status(config: %{registry: nil})
    end

    test "never carries the password; reports reachability and published images",
         %{opts: opts, ctx: ctx} do
      assert {:ok, _} = Publisher.ensure_ready(ctx, opts)

      status = Publisher.status(Keyword.put(opts, :probe, fn _cfg -> :ok end))
      assert status.configured
      assert status.registry == "registry.example.com/arbiter"
      assert status.reachable == true
      assert status.password_set
      assert [%{kind: :worker, ref: ref}] = status.published
      assert Arbiter.Worker.Image.Registry.digest_pinned?(ref)
      refute inspect(status) =~ @password
    end

    test "an unreachable registry and the last publish error show up", %{opts: opts, ctx: ctx} do
      failing = runner(self(), %{"push" => fn _ -> {"boom", 1} end})
      assert {:error, _} = Publisher.ensure_ready(ctx, Keyword.put(opts, :runner, failing))

      status =
        Publisher.status(Keyword.put(opts, :probe, fn _cfg -> {:error, :econnrefused} end))

      assert status.reachable == false
      assert status.reachable_detail =~ "econnrefused"
      assert status.last_error =~ "push_failed"
    end

    test "excluded seed paths are surfaced for the doctor warning", %{opts: opts, ctx: ctx} do
      assert {:ok, _} = Publisher.ensure_ready(%{ctx | seed_paths: ["deps", "priv/plts"]}, opts)
      status = Publisher.status(Keyword.put(opts, :probe, fn _ -> :ok end))
      assert status.seed_excluded == ["priv/plts"]
    end
  end

  defp release_all do
    receive do
      {:push_blocked, pid} ->
        send(pid, :release)
        release_all()
    after
      200 -> :ok
    end
  end
end
