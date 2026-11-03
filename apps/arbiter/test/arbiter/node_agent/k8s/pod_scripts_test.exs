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

    File.write!(
      script,
      String.replace(PodScripts.entry(), PodScripts.env_file(), Path.join(dir, "absent"))
    )

    assert {_out, code} = sh([script, "echo", "ran"])
    assert code != 0
  end
end

defmodule Arbiter.NodeAgent.K8s.PodScriptsEventFeedTest do
  @moduledoc """
  bd-1nl506: with `ARB_EVENTS=1` the entry wrapper tees the command's stdout and stderr to
  an NDJSON file and ships it to the controller (`POST /events`, byte-offset chunks, a
  final chunk at the end). `curl` is a stand-in that keeps what a controller would
  (`Arbiter.NodeAgent.K8s.EventLines` semantics: a retry is trimmed, a gap is refused).
  The command keeps its output on stdout and its exit status.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.EventLines
  alias Arbiter.NodeAgent.K8s.PodScripts

  @moduletag :tmp_dir

  @fake_curl ~S"""
  #!/bin/sh
  dir=$FAKE_DIR
  off=; fin=0; data=; out=
  while [ $# -gt 0 ]; do
    case $1 in
      -H) case $2 in
            x-arb-offset:*) off=${2#x-arb-offset: } ;;
            x-arb-final:*) fin=${2#x-arb-final: } ;;
          esac; shift ;;
      --data-binary) data=${2#@}; shift ;;
      -o) out=$2; shift ;;
    esac
    shift
  done
  echo "$off $fin" >>"$dir/calls"
  left=$(cat "$dir/fail" 2>/dev/null || echo 0)
  if [ "$left" -gt 0 ]; then
    echo $((left - 1)) >"$dir/fail"
    printf 503
    exit 0
  fi
  have=$(wc -c <"$dir/received" 2>/dev/null || echo 0)
  have=$((have + 0))
  if [ "$off" -gt "$have" ]; then
    printf '{"next":%s}' "$have" >"$out"
    printf 409
    exit 0
  fi
  skip=$((have - off))
  size=$(wc -c <"$data")
  if [ "$size" -gt "$skip" ]; then
    tail -c +$((skip + 1)) "$data" >>"$dir/received"
  fi
  have=$(wc -c <"$dir/received")
  [ "$fin" = 1 ] && echo final >"$dir/final"
  printf '{"next":%s}' "$have" >"$out"
  printf 200
  """

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "curl"), @fake_curl)
    File.chmod!(Path.join(bin, "curl"), 0o755)
    fake = Path.join(dir, "fake")
    File.mkdir_p!(fake)
    env_file = Path.join(dir, "env")
    File.write!(env_file, "")
    script = Path.join(dir, "entry.sh")
    File.write!(script, String.replace(PodScripts.entry(), PodScripts.env_file(), env_file))
    %{bin: bin, fake: fake, script: script, home: Path.join(dir, "home")}
  end

  defp run(ctx, argv, extra \\ []) do
    env =
      [
        {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
        {"FAKE_DIR", ctx.fake},
        {"ARB_EVENTS", "1"},
        {"ARB_EVENTS_DIR", Path.join(ctx.home, "ev")},
        {"ARB_RUN_DIR", ctx.home},
        {"ARB_BRIDGE_ADDR", "10.0.0.1"}
      ] ++ extra

    System.cmd("sh", [ctx.script | argv], env: env, stderr_to_stdout: true)
  end

  defp received(ctx), do: File.read!(Path.join(ctx.fake, "received"))

  test "ships stdout and stderr, keeps them on stdout, ends with a final chunk", ctx do
    {out, 0} = run(ctx, ["sh", "-c", ~S/echo one; echo two >&2; echo '{"type":"result"}'/])

    assert out == "one\ntwo\n{\"type\":\"result\"}\n"
    assert received(ctx) == out
    assert File.read!(Path.join(ctx.fake, "final")) == "final\n"
  end

  test "exit status passes through", ctx do
    assert {"bye\n", 7} = run(ctx, ["sh", "-c", "echo bye; exit 7"])
    assert received(ctx) == "bye\n"
  end

  test "a refusing controller is retried without loss or repeat", ctx do
    File.write!(Path.join(ctx.fake, "fail"), "3\n")
    {out, 0} = run(ctx, ["sh", "-c", "echo a; echo b"], [{"ARB_EVENTS_FINAL_TRIES", "20"}])
    assert received(ctx) == out
  end

  test "bytes the controller already holds are not taken twice", ctx do
    File.write!(Path.join(ctx.fake, "received"), "a\n")
    {out, 0} = run(ctx, ["sh", "-c", "echo a; echo b"])
    assert out == "a\nb\n"
    assert received(ctx) == "a\nb\n"
  end

  test "a final line with no newline is never read as a line", ctx do
    {_out, 0} = run(ctx, ["sh", "-c", ~S/printf '{"a":1}\n{"type":"res'/])

    bytes = received(ctx)
    assert bytes == ~s({"a":1}\n{"type":"res)
    {reader, {:ok, lines}} = EventLines.feed(EventLines.new(nil), 0, bytes)
    assert lines == [{"e8", ~s({"a":1}\n)}]
    assert {:truncated, 12} = EventLines.finish(reader)
  end

  test "SIGTERM reaches the command and the feed still ends", ctx do
    env =
      for {k, v} <- [
            {"PATH", ctx.bin <> ":" <> System.get_env("PATH")},
            {"FAKE_DIR", ctx.fake},
            {"ARB_EVENTS", "1"},
            {"ARB_EVENTS_DIR", Path.join(ctx.home, "ev")},
            {"ARB_RUN_DIR", ctx.home},
            {"ARB_BRIDGE_ADDR", "10.0.0.1"}
          ],
          do: {String.to_charlist(k), String.to_charlist(v)}

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        env: env,
        args: [ctx.script, "sh", "-c", "echo started; exec sleep 30"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert_receive {^port, {:data, "started\n"}}, 5_000
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])

    assert_receive {^port, {:exit_status, status}}, 10_000
    assert status == 143
    assert received(ctx) == "started\n"
    assert File.read!(Path.join(ctx.fake, "final")) == "final\n"
  end

  test "a hostile argv word is still just an argument", ctx do
    word = "a; touch #{ctx.tmp_dir}/pwned $(id) `id`"
    {out, 0} = run(ctx, ["printf", "%s", word])
    assert out == word
    refute File.exists?(Path.join(ctx.tmp_dir, "pwned"))
  end

  test "with ARB_EVENTS off the wrapper just execs", ctx do
    {out, 0} = run(ctx, ["echo", "plain"], [{"ARB_EVENTS", "0"}])
    assert out == "plain\n"
    refute File.exists?(Path.join(ctx.fake, "calls"))
  end
end
