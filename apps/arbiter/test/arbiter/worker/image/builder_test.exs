defmodule Arbiter.Worker.Image.BuilderTest do
  @moduledoc """
  bd-9r5jdt (P4): single-flight lazy builds. Concurrent requests for one tag
  produce one `podman build`; a cached tag builds nothing; a failed build
  fails every waiter and is retried by the next request; and the build that
  runs is the default branch's Containerfile in an empty context.
  """

  # async: false — a named-less Builder per test, but the scratch dir is shared.
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder

  @digest String.duplicate("c", 64)

  defp resolver, do: fn _ref -> {:ok, "sha256:" <> @digest} end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "builder-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true
      )

    out
  end

  defp repo(containerfile) do
    dir = tmp_dir()
    git!(dir, ["init", "-q", "-b", "main"])
    File.mkdir_p!(Path.join(dir, ".arbiter"))
    File.write!(Path.join(dir, ".arbiter/Containerfile"), containerfile)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  # A fake podman: `image exists` answers from a set of built tags, `build`
  # records the Containerfile it was given and (optionally) waits for the test.
  defp start_fake(test_pid, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{tags: MapSet.new(opts[:tags] || []), builds: []} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    gate? = Keyword.get(opts, :gate, false)
    fail? = Keyword.get(opts, :fail, false)

    runner = fn "podman", args, _ ->
      case args do
        ["image", "exists", tag] ->
          if Agent.get(agent, &MapSet.member?(&1.tags, tag)), do: {"", 0}, else: {"", 1}

        ["build" | rest] ->
          file = value_of(rest, "--file")
          tag = value_of(rest, "--tag")
          context = List.last(rest)

          record = %{
            tag: tag,
            args: rest,
            containerfile: File.read!(file),
            context_entries: File.ls!(context)
          }

          Agent.update(agent, &%{&1 | builds: [record | &1.builds]})
          send(test_pid, {:build_started, tag, self()})

          if gate? do
            receive do
              :go -> :ok
            end
          end

          if fail? do
            {"boom: build failed", 1}
          else
            Agent.update(agent, &%{&1 | tags: MapSet.put(&1.tags, tag)})
            {"built", 0}
          end
      end
    end

    {agent, runner}
  end

  defp value_of(args, flag) do
    args |> Enum.chunk_every(2, 1, :discard) |> Enum.find_value(fn [f, v] -> f == flag && v end)
  end

  defp flag_pairs(args), do: Enum.chunk_every(args, 2, 1, :discard)

  defp builds(agent), do: agent |> Agent.get(& &1.builds) |> Enum.reverse()

  # Block until `count` callers are queued on the in-flight build of `tag`.
  defp await_waiters(builder, tag, count, attempts \\ 200_000) do
    waiting = builder |> :sys.get_state() |> Map.fetch!(:inflight) |> Map.get(tag, []) |> length()

    cond do
      waiting >= count -> :ok
      attempts == 0 -> flunk("only #{waiting} of #{count} callers queued on #{tag}")
      true -> await_waiters(builder, tag, count, attempts - 1)
    end
  end

  defp start_builder do
    start_supervised!({Builder, name: nil})
  end

  setup do
    {:ok, scratch: tmp_dir()}
  end

  defp plan!(repo_path, extra \\ []) do
    {:ok, plan} = Image.plan(repo_path, "main", [resolver: resolver()] ++ extra)
    plan
  end

  test "builds the base, then the toolchain layer, from an empty context", %{scratch: scratch} do
    {agent, runner} = start_fake(self())
    builder = start_builder()
    plan = plan!(repo("FROM ${ARBITER_BASE}\nRUN echo toolchain\n"))

    assert {:ok, %{tag: tag, built: built}} =
             Builder.ensure(builder, plan, runner: runner, scratch: scratch)

    assert tag == plan.tag
    assert built == [plan.base.tag, plan.tag]

    [base, toolchain] = builds(agent)
    assert base.tag == plan.base.tag
    assert toolchain.tag == plan.tag
    assert toolchain.containerfile =~ "RUN echo toolchain"
    assert toolchain.containerfile =~ "FROM ${ARBITER_BASE}"

    assert ["--build-arg", "ARBITER_BASE=#{plan.base.tag}"] in flag_pairs(toolchain.args)

    # Empty build context: a toolchain Containerfile cannot COPY repo content.
    assert toolchain.context_entries == []
    assert base.context_entries == []

    # Labelled so `list/1` and `prune/1` find it.
    assert ["--label", "arbiter.dev-image=1"] in flag_pairs(toolchain.args)
  end

  test "a cached tag builds nothing", %{scratch: scratch} do
    plan = plan!(repo("FROM ${ARBITER_BASE}\n"))
    {agent, runner} = start_fake(self(), tags: [plan.tag, plan.base.tag])
    builder = start_builder()

    assert {:ok, %{tag: tag, built: []}} =
             Builder.ensure(builder, plan, runner: runner, scratch: scratch)

    assert tag == plan.tag
    assert builds(agent) == []
  end

  test "only the missing layer is built", %{scratch: scratch} do
    plan = plan!(repo("FROM ${ARBITER_BASE}\n"))
    {agent, runner} = start_fake(self(), tags: [plan.base.tag])
    builder = start_builder()

    assert {:ok, %{built: [tag]}} =
             Builder.ensure(builder, plan, runner: runner, scratch: scratch)

    assert tag == plan.tag
    assert [%{tag: ^tag}] = builds(agent)
  end

  test "concurrent requests for one tag produce one build per layer", %{scratch: scratch} do
    {agent, runner} = start_fake(self(), gate: true)
    builder = start_builder()
    plan = plan!(repo("FROM ${ARBITER_BASE}\nRUN echo once\n"))

    callers =
      for _ <- 1..6 do
        Task.async(fn -> Builder.ensure(builder, plan, runner: runner, scratch: scratch) end)
      end

    # The base build is in flight with every caller queued behind it.
    assert_receive {:build_started, base_tag, base_pid}, 5_000
    assert base_tag == plan.base.tag
    await_waiters(builder, plan.base.tag, 6)
    send(base_pid, :go)

    # ... then the toolchain build, again with all six waiting on the one build.
    assert_receive {:build_started, tag, pid}, 5_000
    assert tag == plan.tag
    await_waiters(builder, plan.tag, 6)
    send(pid, :go)

    results = Task.await_many(callers, 10_000)
    assert Enum.all?(results, &match?({:ok, %{tag: ^tag}}, &1))
    assert length(builds(agent)) == 2
    refute_received {:build_started, _, _}
  end

  test "different tags build independently and in parallel", %{scratch: scratch} do
    {agent, runner} = start_fake(self(), gate: true)
    builder = start_builder()
    a = plan!(repo("FROM ${ARBITER_BASE}\nRUN echo a\n"))
    b = plan!(repo("FROM ${ARBITER_BASE}\nRUN echo b\n"))
    refute a.tag == b.tag
    assert a.base.tag == b.base.tag

    ta = Task.async(fn -> Builder.ensure(builder, a, runner: runner, scratch: scratch) end)
    tb = Task.async(fn -> Builder.ensure(builder, b, runner: runner, scratch: scratch) end)

    assert_receive {:build_started, _base, base_pid}, 5_000
    await_waiters(builder, a.base.tag, 2)
    send(base_pid, :go)

    # Both toolchain builds are running at once, neither waiting on the other.
    assert_receive {:build_started, t1, p1}, 5_000
    assert_receive {:build_started, t2, p2}, 5_000
    assert Enum.sort([t1, t2]) == Enum.sort([a.tag, b.tag])
    send(p1, :go)
    send(p2, :go)

    assert {:ok, _} = Task.await(ta, 10_000)
    assert {:ok, _} = Task.await(tb, 10_000)
    assert length(builds(agent)) == 3
  end

  test "a failed build fails every waiter, leaves nothing behind, and is retried", %{
    scratch: scratch
  } do
    {agent, failing} = start_fake(self(), gate: true, fail: true)
    builder = start_builder()
    plan = plan!(repo("FROM ${ARBITER_BASE}\n"))

    callers =
      for _ <- 1..3 do
        Task.async(fn -> Builder.ensure(builder, plan, runner: failing, scratch: scratch) end)
      end

    assert_receive {:build_started, _tag, pid}, 5_000
    await_waiters(builder, plan.base.tag, 3)
    send(pid, :go)

    for result <- Task.await_many(callers, 10_000) do
      assert {:error, {:build_failed, tag, 1, output}} = result
      assert tag == plan.base.tag
      assert output =~ "boom"
    end

    assert length(builds(agent)) == 1
    assert :sys.get_state(builder) |> Map.fetch!(:inflight) == %{}
    assert File.ls!(scratch) == []

    # A later request starts a fresh build rather than replaying the failure.
    {agent2, ok_runner} = start_fake(self())
    assert {:ok, _} = Builder.ensure(builder, plan, runner: ok_runner, scratch: scratch)
    assert length(builds(agent2)) == 2
  end

  test "the scratch directory is removed after a build", %{scratch: scratch} do
    {_agent, runner} = start_fake(self())
    builder = start_builder()
    plan = plan!(repo("FROM ${ARBITER_BASE}\n"))
    assert {:ok, _} = Builder.ensure(builder, plan, runner: runner, scratch: scratch)
    assert File.ls!(scratch) == []
  end

  describe "Image.ensure/3: default branch only" do
    test "a worker-branch Containerfile is never built", %{scratch: scratch} do
      repo = repo("FROM ${ARBITER_BASE}\nRUN echo default-branch\n")
      git!(repo, ["checkout", "-q", "-b", "worker/evil"])

      File.write!(
        Path.join(repo, ".arbiter/Containerfile"),
        "FROM ${ARBITER_BASE}\nRUN echo evil\n"
      )

      git!(repo, ["commit", "-q", "-am", "evil"])

      File.write!(
        Path.join(repo, ".arbiter/Containerfile"),
        "FROM ${ARBITER_BASE}\nRUN echo dirty\n"
      )

      {agent, runner} = start_fake(self())
      builder = start_builder()

      assert {:ok, %{tag: _}} =
               Image.ensure(repo, "main",
                 resolver: resolver(),
                 runner: runner,
                 scratch: scratch,
                 server: builder
               )

      texts = agent |> builds() |> Enum.map(& &1.containerfile) |> Enum.join("\n")
      assert texts =~ "echo default-branch"
      refute texts =~ "echo evil"
      refute texts =~ "echo dirty"
    end

    test "a default branch that does not exist is an error and builds nothing", %{
      scratch: scratch
    } do
      repo = repo("FROM ${ARBITER_BASE}\n")
      {agent, runner} = start_fake(self())
      builder = start_builder()

      assert {:error, {:no_default_branch, "worker/evil"}} =
               Image.ensure(repo, "worker/evil",
                 resolver: resolver(),
                 runner: runner,
                 scratch: scratch,
                 server: builder
               )

      assert builds(agent) == []
    end
  end
end
