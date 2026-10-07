defmodule Arbiter.NodeAgent.RunSpecTest do
  @moduledoc """
  RW9: the agent accepts a declarative spec and refuses everything it does not
  spell out (`docs/design/remote-workers.md` §7.1). The unsafe-flag refusals are
  the acceptance criterion "the agent refuses specs that ask for unsafe
  container flags".
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.RunSpec

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "run" => "run-1",
        "task" => "bd-abc",
        "name" => "arb-bd-abc-1234",
        "install" => "inst1",
        "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
        "cwd" => "/work/tree",
        "mounts" => [
          %{"kind" => "worktree", "path" => "/work/tree"},
          %{"kind" => "home", "path" => "/tmp/run/home"},
          %{
            "kind" => "cli",
            "name" => "claude",
            "sha256" => String.duplicate("a", 64),
            "path" => "/opt/arbiter/cli/claude"
          }
        ],
        "bridges" => [],
        "env" => %{"FOO" => "bar"},
        "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => "tok"},
        "limits" => %{"memory" => "2g"},
        "command" => ["claude", "--print"]
      },
      overrides
    )
  end

  test "a well-formed spec validates" do
    assert {:ok, %RunSpec{run: "run-1", name: "arb-bd-abc-1234", network: :none} = s} =
             RunSpec.validate(spec())

    assert s.limits == %{memory: "2g"}
    assert s.secrets == %{"CLAUDE_CODE_OAUTH_TOKEN" => "tok"}
    assert Enum.map(s.mounts, & &1.kind) == ["worktree", "home", "cli"]
  end

  describe "refuses unsafe container flags" do
    for flag <-
          ~w(--privileged --cap-add --device --userns --pid --network --security-opt -v --user --entrypoint) do
      test "extra_args #{flag}" do
        assert {:error, {:refused, {:unsafe_flag, unquote(flag)}}} =
                 RunSpec.validate(spec(%{"extra_args" => [unquote(flag)]}))
      end
    end

    test "a flag with a value is still named" do
      assert {:error, {:refused, {:unsafe_flag, "--cap-add"}}} =
               RunSpec.validate(spec(%{"extra_args" => ["--cap-add=SYS_ADMIN"]}))
    end

    test "any other extra arg is refused too" do
      assert {:error, {:refused, {:extra_args_not_allowed, "--rm"}}} =
               RunSpec.validate(spec(%{"extra_args" => ["--rm"]}))
    end

    test "unknown top-level fields cannot smuggle options in" do
      for key <- ["privileged", "podman_args", "volumes", "cap_add", "devices"] do
        assert {:error, {:refused, {:unknown_field, ^key}}} =
                 RunSpec.validate(spec(%{key => true}))
      end
    end

    test "an image, name or run that could be read as a flag" do
      assert {:error, {:refused, {:bad_value, "image.tag"}}} =
               RunSpec.validate(spec(%{"image" => %{"tag" => "--privileged"}}))

      assert {:error, {:refused, {:bad_value, "name"}}} =
               RunSpec.validate(spec(%{"name" => "--privileged"}))

      assert {:error, {:refused, {:bad_value, "run"}}} =
               RunSpec.validate(spec(%{"run" => "../x"}))
    end

    test "host networking and unknown networks" do
      assert {:error, {:refused, {:bad_network, "host"}}} =
               RunSpec.validate(spec(%{"network" => "host"}))
    end

    test "mount kinds the agent does not resolve, and host paths in a mount" do
      assert {:error, {:refused, {:unknown_mount_kind, "host"}}} =
               RunSpec.validate(spec(%{"mounts" => [%{"kind" => "host", "path" => "/etc"}]}))

      assert {:error, {:refused, {:forbidden_path, "/proc/1"}}} =
               RunSpec.validate(
                 spec(%{"mounts" => [%{"kind" => "worktree", "path" => "/proc/1"}]})
               )

      assert {:error, {:refused, {:bad_path, "mounts.worktree.path"}}} =
               RunSpec.validate(
                 spec(%{"mounts" => [%{"kind" => "worktree", "path" => "/a/../etc"}]})
               )
    end

    test "a cli mount outside /opt/arbiter/cli, and one with a bad hash" do
      cli = %{
        "kind" => "cli",
        "name" => "x",
        "sha256" => String.duplicate("b", 64),
        "path" => "/usr/bin/x"
      }

      assert {:error, {:refused, {:forbidden_path, "/usr/bin/x"}}} =
               RunSpec.validate(
                 spec(%{"mounts" => [%{"kind" => "worktree", "path" => "/w"}, cli]})
               )

      assert {:error, {:refused, {:bad_value, "mounts.cli.sha256"}}} =
               RunSpec.validate(
                 spec(%{
                   "mounts" => [
                     %{"kind" => "worktree", "path" => "/w"},
                     %{cli | "sha256" => "zz", "path" => "/opt/arbiter/cli/x"}
                   ]
                 })
               )
    end

    test "nothing may be mounted over the secrets file's directory" do
      assert {:error, {:refused, {:forbidden_path, "/run/arbiter/secrets.env"}}} =
               RunSpec.validate(
                 spec(%{"mounts" => [%{"kind" => "tmp", "path" => "/run/arbiter/secrets.env"}]})
               )
    end

    test "limits other than memory, swap and cpus" do
      assert {:error, {:refused, {:unknown_limit, "cpuset_cpus"}}} =
               RunSpec.validate(spec(%{"limits" => %{"cpuset_cpus" => "0"}}))
    end
  end

  describe "checkout (RW11)" do
    test "a checkout block is validated and defaulted" do
      assert {:ok, %RunSpec{checkout: nil}} = RunSpec.validate(spec())

      assert {:ok, %RunSpec{checkout: co}} =
               RunSpec.validate(
                 spec(%{"checkout" => %{"branch" => "arbiter/bd-abc", "base" => "main"}})
               )

      assert co == %{branch: "arbiter/bd-abc", base: "main", interval_ms: 300_000}

      assert {:ok, %RunSpec{checkout: %{interval_ms: 10_000}}} =
               RunSpec.validate(spec(%{"checkout" => %{"branch" => "b", "interval_s" => 10}}))
    end

    test "refuses a malformed checkout" do
      for bad <- [
            "x",
            %{},
            %{"branch" => "../x"},
            %{"branch" => "-rf"},
            %{"branch" => "a b"},
            %{"branch" => "a..b"},
            %{"branch" => "b", "base" => "x y"},
            %{"branch" => "b", "interval_s" => 1},
            %{"branch" => "b", "interval_s" => 100_000},
            %{"branch" => "b", "extra" => 1}
          ] do
        assert {:error, {:refused, _}} = RunSpec.validate(spec(%{"checkout" => bad})),
               inspect(bad)
      end
    end
  end

  describe "other refusals" do
    test "a spec with no worktree mount" do
      assert {:error, {:refused, {:missing_mount, "worktree"}}} =
               RunSpec.validate(spec(%{"mounts" => []}))
    end

    test "an unsupported version, a non-map, and a missing command" do
      assert {:error, {:refused, {:unsupported_version, 2}}} =
               RunSpec.validate(spec(%{"version" => 2}))

      assert {:error, {:refused, :not_a_map}} = RunSpec.validate("x")

      assert {:error, {:refused, {:missing, "command"}}} =
               RunSpec.validate(spec(%{"command" => []}))
    end

    test "a secret that is also a plain env value" do
      assert {:error, {:refused, {:secret_also_env, "TOK"}}} =
               RunSpec.validate(spec(%{"env" => %{"TOK" => "x"}, "secrets" => %{"TOK" => "y"}}))
    end

    test "env and secret names must be identifiers" do
      assert {:error, {:refused, {:bad_env, "secrets", "A B"}}} =
               RunSpec.validate(spec(%{"secrets" => %{"A B" => "x"}}))
    end
  end

  test "redact/1 hides secrets and prompt content so a spec can be logged" do
    redacted =
      spec(%{
        "mounts" => [
          %{"kind" => "prompt", "path" => "/p", "content" => Base.encode64("secret prompt")}
        ]
      })
      |> RunSpec.redact()

    refute inspect(redacted) =~ "tok"
    refute inspect(redacted) =~ "secret prompt"
    assert redacted["secrets"] == %{"CLAUDE_CODE_OAUTH_TOKEN" => "[redacted]"}
  end
end
