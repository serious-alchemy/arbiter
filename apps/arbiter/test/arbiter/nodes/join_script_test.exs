defmodule Arbiter.Nodes.JoinScriptTest do
  @moduledoc """
  The rendered join script, statically (`docs/design/remote-workers.md` §5.5):
  shellcheck, hygiene, no executed `sudo`, no secret in the one-liner. The
  script's behaviour is run in `join_script_run_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.JoinScript

  @moduletag :tmp_dir

  @url "https://primary.example.ts.net"

  defp script(opts \\ []), do: JoinScript.render(Keyword.merge([public_url: @url], opts))

  describe "one_liner/1" do
    test "pipes the join script to bash in token mode and carries no secret" do
      line = JoinScript.one_liner(@url)

      assert line ==
               "curl --proto '=https' --tlsv1.2 -fsSL #{@url}/nodes/join | ARB_JOIN_MODE=token bash"

      refute line =~ "arbj_"
    end

    test "a loopback http primary (ssh -L) gets plain curl" do
      assert JoinScript.one_liner("http://127.0.0.1:4848") ==
               "curl -fsSL http://127.0.0.1:4848/nodes/join | ARB_JOIN_MODE=token bash"
    end
  end

  describe "render/1 hygiene" do
    test "main is defined and invoked on the last line" do
      lines = script() |> String.split("\n", trim: true)
      assert List.last(lines) == ~s(main "$@")
      assert Enum.count(lines, &String.starts_with?(&1, "main ")) == 1
      assert Enum.any?(lines, &(&1 == "main() {"))
    end

    test "strict mode and umask come before anything else runs" do
      body = script() |> String.split("\n") |> Enum.reject(&(&1 =~ ~r/^\s*(#|$)/))
      assert Enum.take(body, 2) == ["set -euo pipefail", "umask 077"]
    end

    test "is a bash script with a valid syntax", %{tmp_dir: dir} do
      path = Path.join(dir, "join.sh")
      File.write!(path, script())
      assert {"", 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
      assert script() =~ "#!/usr/bin/env bash"
    end

    test "the primary URL, arch and thresholds are baked in, shell-quoted" do
      s = script(arch: "x86_64", min_podman_major: 4)
      assert s =~ "ARB_PRIMARY_URL='#{@url}'"
      assert s =~ "ARB_EXPECT_ARCH='x86_64'"
      assert s =~ "ARB_MIN_PODMAN_MAJOR='4'"
    end

    test "a hostile value cannot break out of its quotes", %{tmp_dir: dir} do
      evil = "https://a.example/'; touch #{dir}/pwned; echo '"
      s = script(public_url: evil)
      path = Path.join(dir, "join.sh")
      File.write!(path, s)
      assert {"", 0} = System.cmd("bash", ["-n", path], stderr_to_stdout: true)
      assert s =~ ~S('https://a.example/'\''; touch)
      # the quote closes and reopens: the payload stays inside one word
      refute s =~ ~r/^[^#'\n]*touch #{Regex.escape(dir)}/m
    end

    test "never asks for the token on argv: it is read from file, env or the tty" do
      s = script()
      assert s =~ "/dev/tty"
      assert s =~ "ARB_JOIN_TOKEN_FILE"
      assert s =~ "ARB_JOIN_TOKEN"
      assert s =~ "ARB_JOIN_CHECK_ONLY"
      # no positional or flag token, no token in a curl argv
      refute s =~ ~r/--token|-t\s+\$/
      refute s =~ ~r/curl[^\n]*\$\{?JOIN_TOKEN/
      refute s =~ ~r/-d\s+"?\$\{?(JOIN_)?TOKEN|--data[^\n]*\$\{?JOIN_TOKEN/
    end

    test "refuses to run as root" do
      assert script() =~ ~r/id -u.*-eq 0/
    end
  end

  describe "sudo" do
    test "appears only inside quoted remediation text handed to `bad`" do
      offenders =
        script()
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.filter(&(&1 =~ ~r/\bsudo\b/))
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?(~s(bad "))))

      assert offenders == []
    end

    test "is absent once comments and quoted strings are removed (never a command)" do
      code =
        script()
        |> String.split("\n")
        |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
        |> Enum.map_join("\n", fn line ->
          line |> String.replace(~r/"[^"]*"/, "") |> String.replace(~r/'[^']*'/, "")
        end)

      refute code =~ ~r/\b(sudo|su|doas|pkexec|run0)\b/
    end
  end

  describe "shellcheck" do
    test "the rendered script passes", %{tmp_dir: dir} do
      case System.find_executable("shellcheck") do
        nil ->
          # CI (ubuntu-latest ships shellcheck) must lint; a laptop without it
          # is told, not blocked.
          if System.get_env("CI"), do: flunk("shellcheck is required on PATH in CI")
          IO.puts(:stderr, "\nWARNING: shellcheck not installed; join script not linted")

        shellcheck ->
          path = Path.join(dir, "join.sh")
          File.write!(path, script())

          assert {"", 0} =
                   System.cmd(shellcheck, ["--shell=bash", "--severity=style", path],
                     stderr_to_stdout: true
                   )
      end
    end
  end
end
