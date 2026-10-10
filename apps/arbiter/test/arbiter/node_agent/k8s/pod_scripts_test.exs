defmodule Arbiter.NodeAgent.K8s.PodScriptsTest do
  @moduledoc "The two rendered scripts really run under `sh` (the pod's shell)."
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.PodScripts

  @moduletag :tmp_dir

  defp sh(args, env \\ []), do: System.cmd("sh", args, env: env, stderr_to_stdout: true)

  test "both scripts parse", %{tmp_dir: dir} do
    for {name, text} <- [seed: PodScripts.seed(), entry: PodScripts.entry()] do
      path = Path.join(dir, "#{name}.sh")
      File.write!(path, text)
      assert {"", 0} = sh(["-n", path])
    end
  end

  test "entry sources the secrets file, deletes it, and execs the argv words", %{tmp_dir: dir} do
    env_file = Path.join(dir, "env")
    File.write!(env_file, "TOKEN=abc\nOTHER=\"x y\"\n")
    script = Path.join(dir, "entry.sh")
    File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), env_file))

    assert {"abc|x y\n", 0} = sh([script, "sh", "-c", ~S/echo "$TOKEN|$OTHER"/])
    refute File.exists?(env_file)
  end

  test "entry passes a hostile argv word through untouched", %{tmp_dir: dir} do
    env_file = Path.join(dir, "env")
    File.write!(env_file, "X=1\n")
    script = Path.join(dir, "entry.sh")
    File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), env_file))

    word = "a; touch #{dir}/pwned $(id) `id`"
    assert {out, 0} = sh([script, "printf", "%s", word])
    assert out == word
    refute File.exists?(Path.join(dir, "pwned"))
  end

  test "entry fails closed when the secrets file is missing", %{tmp_dir: dir} do
    script = Path.join(dir, "entry.sh")
    File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), Path.join(dir, "absent")))
    assert {_out, code} = sh([script, "echo", "ran"])
    assert code != 0
  end
end
