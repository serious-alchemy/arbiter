defmodule Arbiter.Worker.ContainerGitSecretTest do
  @moduledoc """
  bd-9cygoo (G16): the scoped git credential reaches a podman worker as a
  `--secret`, never as a flag value, a mount of a host file or an env literal.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Container

  @moduletag :tmp_dir

  defp spec(extra) do
    Map.merge(
      %{
        podman: "/usr/bin/podman",
        image: "localhost/x:1",
        name: "arb-run1",
        worktree: "/work/tree"
      },
      extra
    )
  end

  defp secrets(argv),
    do:
      argv
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(&(hd(&1) == "--secret"))
      |> Enum.map(&List.last/1)

  test "no secrets, no --secret flag" do
    assert secrets(Container.argv(spec(%{}), ["claude"])) == []
  end

  test "a key secret is a read-only mount for the container's uid; a token secret is an env var" do
    argv =
      Container.argv(
        spec(%{
          podman_secrets: [
            %{name: "arb-run1-git-key", type: :mount, target: "arb_git_key", uid: 1000},
            %{name: "arb-run1-git-token", type: :env, target: "ARB_GIT_TOKEN"}
          ]
        }),
        ["claude"]
      )

    assert secrets(argv) == [
             "arb-run1-git-key,type=mount,target=arb_git_key,uid=1000,mode=0400",
             "arb-run1-git-token,type=env,target=ARB_GIT_TOKEN"
           ]

    # before the image, so they are podman options and not the worker's argv
    assert Enum.find_index(argv, &(&1 == "--secret")) < Enum.find_index(argv, &(&1 == "--"))
  end

  describe "create_secret/2 and remove_secret/2" do
    setup do
      test_pid = self()

      runner = fn cmd, args, opts ->
        send(test_pid, {:podman, cmd, args, opts})

        case args do
          ["secret", "create", _name, file] ->
            send(
              test_pid,
              {:file_during_create, File.read!(file),
               File.stat!(file).mode |> Bitwise.band(0o777)}
            )

            {"id\n", 0}

          _ ->
            {"", 0}
        end
      end

      %{runner: runner}
    end

    test "the value goes in through a 0600 file that is gone afterwards, never argv", %{
      runner: runner,
      tmp_dir: tmp
    } do
      secret = %{
        name: "arb-run1-git-key",
        type: :mount,
        target: "arb_git_key",
        value: "PRIVATE\n"
      }

      assert :ok = Container.create_secret(secret, runner: runner, podman: "podman", dir: tmp)

      assert_received {:podman, "podman", ["secret", "rm", "--ignore", "arb-run1-git-key"], _}
      assert_received {:podman, "podman", ["secret", "create", "arb-run1-git-key", file], _}
      assert_received {:file_during_create, "PRIVATE\n", 0o600}
      refute File.exists?(file)
      refute File.ls!(tmp) |> Enum.any?(&(&1 =~ "secret"))
    end

    test "a failed create is an error and leaves no file", %{tmp_dir: tmp} do
      runner = fn _cmd, args, _opts ->
        if match?(["secret", "create" | _], args), do: {"boom", 125}, else: {"", 0}
      end

      secret = %{
        name: "arb-run1-git-key",
        type: :mount,
        target: "arb_git_key",
        value: "PRIVATE\n"
      }

      assert {:error, {:podman_secret_failed, 125, "boom"}} =
               Container.create_secret(secret, runner: runner, dir: tmp)

      assert File.ls!(tmp) == []
    end

    test "remove_secret removes by name", %{runner: runner} do
      assert :ok = Container.remove_secret("arb-run1-git-key", runner: runner, podman: "podman")
      assert_received {:podman, "podman", ["secret", "rm", "--ignore", "arb-run1-git-key"], _}
    end

    test "reap_git_secrets removes the git secrets of containers that are gone, and only those" do
      runner = fn _cmd, args, _opts ->
        case args do
          ["secret", "ls" | _] ->
            {"arb-live-git-key\narb-dead-git-token\nunrelated-secret\narb-dead-git-key\n", 0}

          ["ps" | _] ->
            {"arb-live\n", 0}

          ["secret", "rm", "--ignore", name] ->
            send(self(), {:removed, name})
            {"", 0}
        end
      end

      assert ["arb-dead-git-key", "arb-dead-git-token"] ==
               Enum.sort(Container.reap_git_secrets(runner: runner))
    end
  end
end
