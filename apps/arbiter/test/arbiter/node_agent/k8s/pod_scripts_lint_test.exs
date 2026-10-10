defmodule Arbiter.NodeAgent.K8s.PodScriptsLintTest do
  @moduledoc """
  K7 (bd-dzyclc): every script the pod runs is POSIX `sh` (the image's `/bin/sh`
  is dash) and passes `shellcheck`: the two programs the base image carries
  (`priv/k8s_pod/seed`, `snapshotter`) and the two rendered into the pod's
  `command:` (`PodScripts.seed/0` with the netpol gate, `entry/0`).

  `shellcheck` is looked up on `PATH` or in `$SHELLCHECK`. CI must have it; a
  laptop without it is told, not blocked (as `join_script_test.exs` does).
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.PodRuntimeHarness, as: H

  @moduletag :tmp_dir

  defp scripts(dir) do
    inline =
      for {name, text} <- [gate: PodScripts.seed(), entry: PodScripts.entry()] do
        path = Path.join(dir, "#{name}.sh")
        File.write!(path, text)
        {to_string(name), path}
      end

    files = for name <- Map.keys(PodScripts.bin()), do: {name, H.script(name)}
    inline ++ files
  end

  test "the image's programs are the files in priv/ and start with an sh shebang" do
    for {name, text} <- PodScripts.bin() do
      assert File.read!(H.script(name)) == text
      assert String.starts_with?(text, "#!/bin/sh\n")
    end
  end

  test "every script parses under the image's shell", %{tmp_dir: dir} do
    for {name, path} <- scripts(dir) do
      assert {"", 0} = System.cmd(H.shell(), ["-n", path], stderr_to_stdout: true),
             "#{name} does not parse under #{H.shell()}"
    end
  end

  test "every script passes shellcheck", %{tmp_dir: dir} do
    case System.get_env("SHELLCHECK") || System.find_executable("shellcheck") do
      nil ->
        if System.get_env("CI"), do: flunk("shellcheck is required on PATH in CI")
        IO.puts(:stderr, "\nWARNING: shellcheck not installed; the pod scripts were not linted")

      shellcheck ->
        for {name, path} <- scripts(dir) do
          assert {"", 0} =
                   System.cmd(shellcheck, ["--shell=sh", "--severity=style", path],
                     stderr_to_stdout: true
                   ),
                 "shellcheck rejects #{name}"
        end
    end
  end
end
