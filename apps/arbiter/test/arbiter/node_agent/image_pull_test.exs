defmodule Arbiter.NodeAgent.ImagePullTest do
  @moduledoc """
  SI4 (`docs/design/remote-workers.md` §21.2.1, §21.4): a machine node pulls the
  published image by its digest with a read credential written only to the run's
  tmpfs, deletes it however the pull ends, and runs nothing whose labels do not
  match what the primary asked for. podman is a stand-in runner that records each
  call and, for `pull`, what the auth file held at that moment.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.{ImagePull, PullAuth, RunSpec, Secrets}

  @moduletag :tmp_dir

  @digest String.duplicate("e", 64)
  @ref "registry.example.com/arbiter/vstim/worker@sha256:" <> @digest
  @password "glpat-PULL-ONLY-s3cr3t"
  @auth %PullAuth{registry: "registry.example.com", username: "deploy-7", password: @password}
  @labels %{
    "arbiter.runtime-contract" => "1",
    "arbiter.cli-set" => "0a1b2c3d",
    "arbiter.cli-providers" => "claude,codex",
    "arbiter.cli.claude.version" => "2.1.310",
    "arbiter.cli.claude.sha256" => String.duplicate("c", 64)
  }

  defp spec(overrides \\ %{}) do
    Map.merge(
      %RunSpec{
        run: "run-pull-1",
        name: "arb-run-pull-1",
        image: %{
          tag: "localhost/arbiter-dev/x:1",
          plan: nil,
          ref: @ref,
          cli_set: "0a1b2c3d",
          provider: "claude",
          insecure?: false
        },
        pull_auth: @auth
      },
      overrides
    )
  end

  # The stand-in podman: `image exists` answers `present?`, `pull` answers `pull`
  # (after recording the auth file it was handed), `image inspect` answers `labels`.
  defp runner(test, cfg) do
    fn "podman", args, _opts ->
      send(test, {:podman, args})

      case args do
        ["image", "exists", _ref] ->
          if Map.get(cfg, :present?, false), do: {"", 0}, else: {"", 1}

        ["pull" | rest] ->
          send(test, {:authfile, authfile_seen(rest)})
          Map.get(cfg, :pull, {"Copying blob sha256:1\nWriting manifest\n", 0})

        ["image", "inspect", _ref] ->
          Map.get(
            cfg,
            :inspect,
            {Jason.encode!([%{"Labels" => Map.get(cfg, :labels, @labels)}]), 0}
          )
      end
    end
  end

  defp authfile_seen(args) do
    case Enum.drop_while(args, &(&1 != "--authfile")) do
      ["--authfile", path | _] ->
        {:ok, stat} = File.lstat(path)

        %{
          path: path,
          type: stat.type,
          mode: Bitwise.band(stat.mode, 0o777),
          body: File.read!(path)
        }

      _ ->
        nil
    end
  end

  defp opts(ctx, cfg \\ %{}) do
    [
      podman: "podman",
      runner: runner(self(), cfg),
      runtime_dir: ctx.rt,
      mountinfo: mountinfo(ctx.rt, Map.get(cfg, :fs, "tmpfs"))
    ]
  end

  defp mountinfo(rt, type) do
    path = Path.expand(Path.join([rt, "..", "mountinfo-#{type}"]))
    File.write!(path, "36 35 98:0 / #{rt} rw,noatime - #{type} none rw\n")
    path
  end

  setup %{tmp_dir: tmp} do
    rt = Path.join(tmp, "rt")
    File.mkdir_p!(rt)
    %{rt: rt}
  end

  describe "pulling a digest the node does not hold" do
    test "the credential is a 0600 auth file on the run's tmpfs, gone once the pull ends", ctx do
      assert :ok = ImagePull.ensure(spec(), opts(ctx))

      assert_received {:podman, ["image", "exists", @ref]}
      assert_received {:podman, ["pull" | pull_args]}
      assert_received {:authfile, seen}
      assert_received {:podman, ["image", "inspect", @ref]}

      assert pull_args == ["--quiet", "--authfile", seen.path, @ref]
      assert seen.path == Secrets.authfile(ctx.rt, "run-pull-1")
      assert seen.type == :regular
      assert seen.mode == 0o600

      assert Jason.decode!(seen.body) == %{
               "auths" => %{
                 "registry.example.com" => %{
                   "auth" => Base.encode64("deploy-7:" <> @password)
                 }
               }
             }

      refute File.exists?(seen.path)
      refute Enum.any?(pull_args, &String.contains?(&1, @password))
    end

    test "an insecure registry is pulled with --tls-verify=false, and only then", ctx do
      insecure = spec(%{image: %{spec().image | insecure?: true}})
      assert :ok = ImagePull.ensure(insecure, opts(ctx))
      assert_received {:podman, ["pull" | args]}
      assert "--tls-verify=false" in args

      assert :ok = ImagePull.ensure(spec(), opts(ctx))
      assert_received {:podman, ["pull" | args]}
      refute "--tls-verify=false" in args
    end

    test "an anonymous pull (no pull_auth) is made with no auth file", ctx do
      assert :ok = ImagePull.ensure(spec(%{pull_auth: nil}), opts(ctx))
      assert_received {:podman, ["pull", "--quiet", @ref]}
      assert_received {:authfile, nil}
    end

    test "a failed pull is pull_failed, its output scrubbed of the credential, the file gone",
         ctx do
      echo = "Error: auth #{@password} / #{Base.encode64("deploy-7:" <> @password)} denied"
      cfg = %{pull: {echo, 125}}

      assert {:error, {:image_unavailable, {:pull_failed, 125, out}}} =
               ImagePull.ensure(spec(), opts(ctx, cfg))

      refute out =~ @password
      refute out =~ Base.encode64("deploy-7:" <> @password)
      assert out =~ "denied"
      assert_received {:authfile, %{path: path}}
      refute File.exists?(path)
      refute_received {:podman, ["image", "inspect", _]}
    end

    test "a pull that raises still removes the auth file", ctx do
      test = self()

      raising = fn "podman", args, _ ->
        case args do
          ["image", "exists", _] ->
            {"", 1}

          ["pull" | rest] ->
            send(test, {:authfile, authfile_seen(rest)})
            raise "podman went away"
        end
      end

      assert_raise RuntimeError, fn ->
        ImagePull.ensure(spec(), Keyword.put(opts(ctx), :runner, raising))
      end

      assert_received {:authfile, %{path: path}}
      refute File.exists?(path)
    end

    test "with no tmpfs nothing is written and nothing pulled: the run is unschedulable", ctx do
      assert {:error, {:unschedulable, {:secrets_not_on_tmpfs, _root, "ext4"}}} =
               ImagePull.ensure(spec(), opts(ctx, %{fs: "ext4"}))

      refute_received {:podman, ["pull" | _]}
      refute File.exists?(Secrets.dir(ctx.rt, "run-pull-1"))
    end
  end

  test "a node that holds the digest runs it without the registry (no pull, no auth file)",
       ctx do
    assert :ok = ImagePull.ensure(spec(), opts(ctx, %{present?: true}))
    refute_received {:podman, ["pull" | _]}
    refute_received {:authfile, _}
    # the labels are checked on a warm node too
    assert_received {:podman, ["image", "inspect", @ref]}
  end

  describe "prefetch/5 (SI7)" do
    test "pulls with the same tmpfs auth file, deletes it, and runs no label check", ctx do
      assert :ok = ImagePull.prefetch(@ref, %{}, @auth, "prefetch-1", opts(ctx))

      assert_received {:podman, ["image", "exists", @ref]}
      assert_received {:podman, ["pull", "--quiet", "--authfile", path, @ref]}
      assert_received {:authfile, %{mode: 0o600}}
      assert path == Secrets.authfile(ctx.rt, "prefetch-1")
      refute File.exists?(path)
      refute_received {:podman, ["image", "inspect", _]}
    end

    test "a node that holds the digest pulls nothing", ctx do
      opts = opts(ctx, %{present?: true})
      assert :ok = ImagePull.prefetch(@ref, %{}, @auth, "prefetch-1", opts)
      refute_received {:podman, ["pull" | _]}
    end

    test "a failed pull is an error with the credential scrubbed", ctx do
      opts = opts(ctx, %{pull: {"denied for " <> @password, 125}})

      assert {:error, {:image_unavailable, {:pull_failed, 125, out}}} =
               ImagePull.prefetch(@ref, %{}, @auth, "prefetch-1", opts)

      refute out =~ @password
    end
  end

  describe "the label checks (contract_mismatch)" do
    test "the runtime contract must be one this agent supports" do
      assert ImagePull.runtime_contracts() == [1]
    end

    for {label, value, item} <- [
          {"arbiter.runtime-contract", nil, "arbiter.runtime-contract"},
          {"arbiter.runtime-contract", "2", "arbiter.runtime-contract"},
          {"arbiter.runtime-contract", "one", "arbiter.runtime-contract"},
          {"arbiter.cli-set", "ffffffff", "arbiter.cli-set"},
          {"arbiter.cli-set", nil, "arbiter.cli-set"},
          {"arbiter.cli.claude.version", nil, "arbiter.cli.claude"},
          {"arbiter.cli.claude.sha256", "", "arbiter.cli.claude"},
          {"arbiter.cli-providers", "codex", "arbiter.cli.claude"}
        ] do
      test "#{label} = #{inspect(value)} refuses the image as #{item}", ctx do
        labels =
          if is_nil(unquote(value)),
            do: Map.delete(@labels, unquote(label)),
            else: Map.put(@labels, unquote(label), unquote(value))

        assert {:error, {:image_unavailable, {:contract_mismatch, unquote(item), _found}}} =
                 ImagePull.ensure(spec(), opts(ctx, %{present?: true, labels: labels}))
      end
    end

    test "a spec that names no CLI set or provider cannot be checked, so it is refused", ctx do
      for image <- [Map.delete(spec().image, :cli_set), Map.delete(spec().image, :provider)] do
        assert {:error, {:image_unavailable, {:contract_mismatch, _item, _}}} =
                 ImagePull.ensure(spec(%{image: image}), opts(ctx, %{present?: true}))
      end
    end

    test "an image with no labels at all, or inspect output that is not JSON", ctx do
      assert {:error, {:image_unavailable, {:contract_mismatch, "arbiter.runtime-contract", nil}}} =
               ImagePull.ensure(
                 spec(),
                 opts(ctx, %{present?: true, inspect: {~s([{"Labels": null}]), 0}})
               )

      assert {:error, {:image_unavailable, {:inspect_failed, _}}} =
               ImagePull.ensure(spec(), opts(ctx, %{present?: true, inspect: {"WARN", 0}}))

      assert {:error, {:image_unavailable, {:inspect_failed, _}}} =
               ImagePull.ensure(spec(), opts(ctx, %{present?: true, inspect: {"no such", 125}}))
    end

    test "labels under Config.Labels (another podman's shape) are read too", ctx do
      out = Jason.encode!([%{"Config" => %{"Labels" => @labels}}])
      assert :ok = ImagePull.ensure(spec(), opts(ctx, %{present?: true, inspect: {out, 0}}))
    end
  end
end
