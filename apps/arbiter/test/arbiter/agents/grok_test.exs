defmodule Arbiter.Agents.GrokTest do
  # async: false — PATH and the jail / home Application env are global.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Grok
  alias Arbiter.Agents.Grok.ConfigDir
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.StopReason

  @moduletag :capture_log

  # Real captures from the bd-7nbwix live probe (see Grok.StreamTest).
  @fixtures Path.expand("../../fixtures/grok", __DIR__)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "grok-adapter-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(base, "bin")
    worktree = Path.join(base, "wt")
    File.mkdir_p!(bin)
    File.mkdir_p!(worktree)

    for name <- ~w(grok bwrap) do
      File.write!(Path.join(bin, name), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, name), 0o755)
    end

    keys = ~w(worker_grok_home_root worker_jail_available worker_jail_bwrap grok_credential_env)a
    prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
    old_path = System.get_env("PATH")

    Application.put_env(:arbiter, :worker_grok_home_root, Path.join(base, "homes"))
    Application.put_env(:arbiter, :worker_jail_available, true)
    Application.put_env(:arbiter, :worker_jail_bwrap, Path.join(bin, "bwrap"))
    Application.delete_env(:arbiter, :grok_credential_env)
    System.put_env("PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", old_path)

      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:arbiter, k)
        {k, v} -> Application.put_env(:arbiter, k, v)
      end)

      File.rm_rf!(base)
    end)

    {:ok, base: base, bin: bin, worktree: worktree, grok: Path.join(bin, "grok")}
  end

  defp policy(mode, sandbox \\ %{}),
    do:
      SecurityPolicy.merge(SecurityPolicy.base(), %{
        permissions: %{mode: mode},
        sandbox: sandbox
      })

  # `sh -c 'exec "$@" < /dev/null' sh <jail...> -- <grok ...>`
  defp split(argv) do
    assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | rest] = argv
    {jail, ["--" | command]} = Enum.split_while(rest, &(&1 != "--"))
    {jail, command}
  end

  defp triples(jail), do: Enum.chunk_every(jail, 3, 1)

  describe "behaviour" do
    test "implements Agent, provider grok, sentinel matches `arb done`" do
      behaviours =
        Grok.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Arbiter.Agents.Agent in behaviours
      assert Grok.provider() == "grok"
      assert Regex.match?(Grok.done_sentinel(), "work finished\narb done")
      refute Regex.match?(Grok.done_sentinel(), "arb doneness")
    end
  end

  describe "default_argv/2" do
    test "runs grok under the Worker.Jail with the isolated HOME bound", %{
      worktree: wt,
      grok: grok,
      bin: bin
    } do
      assert {:ok, argv} =
               Grok.default_argv("do the thing", worktree: wt, security: policy(:auto))

      {jail, command} = split(argv)
      home = ConfigDir.path(worktree: wt)

      assert [bwrap, "--ro-bind", "/", "/" | _] = jail
      assert bwrap == Path.join(bin, "bwrap")
      assert ["--bind", wt, wt] in triples(jail)
      assert ["--bind", home, home] in triples(jail)
      assert ["--setenv", "HOME", home] in triples(jail)
      assert ["--setenv", "GROK_HOME", Path.join(home, ".grok")] in triples(jail)
      assert "--unshare-pid" in jail

      assert [^grok, "-p", "do the thing" | flags] = command
      assert ["--output-format", "streaming-messages-json"] == Enum.slice(flags, 0, 2)
      assert "--always-approve" in flags
      assert "--no-auto-update" in flags

      assert ["--max-turns", turns] =
               Enum.chunk_every(flags, 2, 1) |> Enum.find(&(hd(&1) == "--max-turns"))

      assert String.to_integer(turns) > 0
      refute "--sandbox" in command
      refute "-m" in flags
      refute "--effort" in flags
    end

    test "model and effort become -m / --effort", %{worktree: wt} do
      assert {:ok, argv} =
               Grok.default_argv("p",
                 worktree: wt,
                 model: "grok-4.7",
                 thinking: "high",
                 max_turns: 12
               )

      {_jail, command} = split(argv)
      assert ["-m", "grok-4.7"] in Enum.chunk_every(command, 2, 1)
      assert ["--effort", "high"] in Enum.chunk_every(command, 2, 1)
      assert ["--max-turns", "12"] in Enum.chunk_every(command, 2, 1)
    end

    test "an oversize prompt goes in a prompt file under the bound home, not argv", %{
      worktree: wt
    } do
      prompt = String.duplicate("x", 140_000)
      assert {:ok, argv} = Grok.default_argv(prompt, worktree: wt)
      {_jail, command} = split(argv)

      assert [_grok, "-p", "--prompt-file", file | _] = command
      home = ConfigDir.path(worktree: wt)
      assert String.starts_with?(file, home <> "/")
      assert File.read!(file) == prompt
      refute prompt in command
    end

    test "a review dispatch (Write denied) binds the worktree read-only", %{worktree: wt} do
      deny_write = SecurityPolicy.merge(policy(:auto), %{permissions: %{deny: ["Write"]}})
      assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: deny_write)
      {jail, _} = split(argv)
      assert ["--ro-bind", wt, wt] in triples(jail)
      refute ["--bind", wt, wt] in triples(jail)
    end

    test ":strict refuses rather than run unjailed when the host can't jail", %{worktree: wt} do
      Application.put_env(:arbiter, :worker_jail_available, false)

      assert {:error, {:write_jail_unavailable, _}} =
               Grok.default_argv("p", worktree: wt, security: policy(:strict))
    end

    test "outside :strict an unjailable host runs grok unjailed but still isolated", %{
      worktree: wt,
      grok: grok
    } do
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: policy(:auto))
      assert ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", ^grok, "-p", "p" | _] = argv
    end

    test "no grok on PATH is an error", %{worktree: wt, bin: bin} do
      File.rm!(Path.join(bin, "grok"))
      assert {:error, {:executable_not_found, "grok"}} = Grok.default_argv("p", worktree: wt)
    end
  end

  describe "spawn_env/1" do
    test "isolates HOME/GROK_HOME and switches off update, telemetry upload, memory, colour", %{
      worktree: wt
    } do
      env = Grok.spawn_env(worktree: wt)
      home = ConfigDir.path(worktree: wt)

      assert {"HOME", home} in env
      assert {"GROK_HOME", Path.join(home, ".grok")} in env
      assert {"GROK_DISABLE_AUTOUPDATER", "1"} in env
      assert {"GROK_TELEMETRY_TRACE_UPLOAD", "0"} in env
      assert {"GROK_MEMORY", "0"} in env
      assert {"NO_COLOR", "1"} in env
    end

    test "strips an inherited XAI_API_KEY / auth command unless the credential seam supplies one",
         %{
           worktree: wt
         } do
      env = Grok.spawn_env(worktree: wt)
      assert {"XAI_API_KEY", false} in env
      assert {"GROK_AUTH_PROVIDER_COMMAND", false} in env

      Application.put_env(:arbiter, :grok_credential_env, [
        {"GROK_AUTH_PROVIDER_COMMAND", "broker"}
      ])

      env = Grok.spawn_env(worktree: wt)
      assert {"GROK_AUTH_PROVIDER_COMMAND", "broker"} in env
      refute {"GROK_AUTH_PROVIDER_COMMAND", false} in env
      assert {"XAI_API_KEY", false} in env
    end
  end

  describe "security policy (bd-761q6h)" do
    defp denied(command) do
      command
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(&(hd(&1) == "--deny"))
      |> Enum.map(&List.last/1)
    end

    test "security_enforced?/0 is true: the baseline rides on every spawn" do
      assert Grok.security_enforced?()
    end

    test "the default policy's deny baseline reaches grok next to --always-approve", %{
      worktree: wt
    } do
      assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: policy(:bypass))
      {_jail, command} = split(argv)

      assert "--always-approve" in command
      rules = denied(command)
      assert "Bash(rm -rf:*)" in rules
      assert "Bash(git push --force:*)" in rules
      assert "Bash(gh pr create:*)" in rules
      assert "Read(**/.env)" in rules
      assert "WebFetch(domain:catbox.moe)" in rules
      assert Enum.any?(rules, &String.starts_with?(&1, "Edit(/etc"))

      # The worker's own GROK_HOME (its credential seam) is not editable.
      assert "Edit(#{ConfigDir.grok_home(worktree: wt)}/**)" in rules

      assert ["--disallowed-tools", tools] =
               Enum.chunk_every(command, 2, 1) |> Enum.find(&(hd(&1) == "--disallowed-tools"))

      assert "monitor" in String.split(tools, ",")
      refute "--sandbox" in command
    end

    test "the security flags are the same in every mode, :strict included", %{worktree: wt} do
      rules =
        for mode <- [:bypass, :auto, :strict] do
          assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: policy(mode))
          {_jail, command} = split(argv)
          denied(command)
        end

      assert [one] = Enum.uniq(rules)
      assert one != []
    end

    test "a review dispatch gets the write tools removed on top of the read-only worktree", %{
      worktree: wt
    } do
      reviewer =
        SecurityPolicy.merge(policy(:bypass), %{
          permissions: %{deny: ["Edit", "Write", "NotebookEdit"]}
        })

      assert {:ok, argv} = Grok.default_argv("review", worktree: wt, security: reviewer)
      {jail, command} = split(argv)

      assert ["--ro-bind", wt, wt] in triples(jail)
      refute ["--bind", wt, wt] in triples(jail)
      assert "Edit" in denied(command)
      assert "Write" in denied(command)
      # grok aborts on `--deny NotebookEdit`; it must never be emitted.
      refute "NotebookEdit" in denied(command)

      [tools] =
        for [flag, value] <- Enum.chunk_every(command, 2, 1),
            flag == "--disallowed-tools",
            do: value

      assert Enum.all?(~w(write search_replace), &(&1 in String.split(tools, ",")))
    end

    test "network: false switches grok's web tools off", %{worktree: wt} do
      assert {:ok, argv} =
               Grok.default_argv("p", worktree: wt, security: policy(:auto, %{network: false}))

      {_jail, command} = split(argv)
      assert "--disable-web-search" in command
      assert "WebSearch" in denied(command)

      assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: policy(:auto))
      {_jail, command} = split(argv)
      refute "--disable-web-search" in command
    end

    test "an operator deny entry grok cannot express is dropped from argv, not passed through", %{
      worktree: wt
    } do
      p = SecurityPolicy.merge(policy(:auto), %{permissions: %{deny: ["Foo(bar)", "Bash(ls:*)"]}})
      assert {:ok, argv} = Grok.default_argv("p", worktree: wt, security: p)
      {_jail, command} = split(argv)

      assert "Bash(ls:*)" in denied(command)
      refute "Foo(bar)" in denied(command)
    end
  end

  describe "confinement" do
    test "write_confinement is :os_jail where the jail applies, :none otherwise" do
      assert Grok.write_confinement(policy(:auto)) == :os_jail
      assert Grok.write_confinement(policy(:auto, %{enabled: false})) == :none
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Grok.write_confinement(policy(:auto)) == :none
    end

    test "write_jail_warning names the gap only when the jail is wanted but unavailable" do
      assert Grok.write_jail_warning(policy(:auto)) == nil
      Application.put_env(:arbiter, :worker_jail_available, false)
      assert Grok.write_jail_warning(policy(:auto)) =~ "grok write jail unavailable"
      assert Grok.write_jail_warning(policy(:auto, %{enabled: false})) == nil
    end
  end

  describe "auth_probe_argv/1" do
    test "is `grok models` with one retry for the not-authenticated-while-refreshing case", %{
      grok: grok
    } do
      assert {:ok, ["sh", "-c", script, "sh", ^grok]} = Grok.auth_probe_argv()
      assert script =~ ~s("$@" models)
      assert script =~ "not authenticated"
      assert script =~ "exit 1"
    end

    test "the probe script exits non-zero only when still unauthenticated after the retry", %{
      base: base,
      bin: bin
    } do
      state = Path.join(base, "calls")

      # PATH is only the stub dir: sleep must exist, and the fake grok may only
      # use shell builtins.
      File.write!(Path.join(bin, "sleep"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, "sleep"), 0o755)

      File.write!(Path.join(bin, "grok"), """
      #!/bin/sh
      if [ "$GROK_FAKE" = "refresh" ] && [ ! -f #{state} ]; then
        : > #{state}; echo "You are not authenticated."
      else
        echo "You are logged in."
      fi
      """)

      {:ok, argv} = Grok.auth_probe_argv()
      ["sh" | args] = argv
      exec = "/bin/sh"

      assert {out, 0} =
               System.cmd(exec, args, env: [{"GROK_FAKE", "refresh"}], stderr_to_stdout: true)

      assert out =~ "logged in"
      assert File.exists?(state)

      File.write!(Path.join(bin, "grok"), "#!/bin/sh\necho 'You are not authenticated.'\n")
      assert {out, 1} = System.cmd(exec, args, stderr_to_stdout: true)
      assert StopReason.classify(1, String.split(out, "\n"), "grok").category == :auth_expired
    end
  end

  # ---- stream parsing through the real session parser ---------------------

  defp feed(name, session \\ Grok.init_session([])) do
    @fixtures
    |> Path.join(name)
    |> File.stream!()
    |> Enum.reduce({[], session}, fn line, {shown, s} ->
      {display, s} = Grok.parse_line(s, String.trim_trailing(line, "\n"))
      {shown ++ display, s}
    end)
  end

  describe "parse_line/2 on the recorded success stream" do
    setup do: {:ok, run: feed("success_stream.jsonl")}

    test "displays decoded Bash output, mapped tool names and thinking, none of it arming done",
         %{
           run: {shown, _}
         } do
      text = Enum.map_join(shown, "\n", &elem(&1, 0))
      assert text =~ "⏵ Bash("
      assert text =~ "⏵ Write("
      assert text =~ "⏴ On branch main"
      refute text =~ ~s("output":[)
      assert text =~ "The user wants me to create two files"

      refute Enum.any?(shown, fn {line, armed?} ->
               armed? and (String.starts_with?(line, "⏵") or line =~ "On branch main")
             end)
    end

    test "usage keeps cached and uncached input apart and takes the result totals", %{
      run: {_, session}
    } do
      usage = Grok.usage_attrs(session)
      assert usage.provider == "grok"
      assert usage.model == "grok-4.7"
      assert usage.tokens_in == 29_112
      assert usage.cache_read_tokens == 31_872
      assert usage.tokens_out == 658
      assert usage.cache_creation_tokens == 0
      assert usage.cost_usd == 0.078108
      assert usage.result_subtype == "success"
      assert usage.is_error == false
    end

    test "the final assistant text is what arms completion" do
      {shown, _} = feed("success_stream.jsonl")
      refute Enum.any?(shown, fn {line, armed?} -> armed? and line =~ "tool result" end)

      session = Grok.init_session([])

      event =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "all set\narb done"}]}
        })

      {display, _} = Grok.parse_line(session, event)
      assert {"arb done", true} in display
      assert Regex.match?(Grok.done_sentinel(), "all set\narb done")
    end
  end

  describe "parse_line/2 on a run cut off before its result line (SIGTERM, 143)" do
    test "per-message usage is all the ledger gets, cached separate" do
      lines =
        @fixtures
        |> Path.join("success_stream.jsonl")
        |> File.stream!()
        |> Enum.take(4)

      session =
        Enum.reduce(lines, Grok.init_session([]), fn line, s ->
          {_, s} = Grok.parse_line(s, String.trim_trailing(line, "\n"))
          s
        end)

      usage = Grok.usage_attrs(session)
      assert usage.tokens_in == 11_680 + 2_338
      assert usage.cache_read_tokens == 1_664 + 13_312
      refute Map.has_key?(usage, :result_subtype)
    end
  end

  describe "parse_line/2 on error results" do
    test "zero usage with is_error is recorded as unknown, not zero" do
      {_, session} = feed("error_not_signed_in.jsonl")
      usage = Grok.usage_attrs(session)
      assert usage.is_error == true
      assert usage.result_subtype == "error_during_execution"
      refute Map.has_key?(usage, :tokens_in)
      refute Map.has_key?(usage, :cost_usd)
    end

    test "the error text reaches the transcript and classifies as auth_expired" do
      {shown, _} = feed("error_not_signed_in.jsonl")
      lines = Enum.map(shown, &elem(&1, 0))
      assert Enum.any?(lines, &(&1 =~ "Not signed in"))
      refute Enum.any?(shown, fn {_, armed?} -> armed? end)
      assert StopReason.classify(1, lines, "grok").category == :auth_expired
    end

    test "a bad model is a crash (exit 1), never a clean exit" do
      {shown, _} = feed("error_bad_model.jsonl")
      lines = Enum.map(shown, &elem(&1, 0))
      assert Enum.any?(lines, &(&1 =~ "unknown model id"))
      assert StopReason.classify(1, lines, "grok").category == :crashed
    end
  end

  describe "exit mapping" do
    test "SIGTERM (143) and SIGINT (130) are killed, exit 0 without done is exited_without_done" do
      {shown, _} = feed("success_stream.jsonl")
      lines = Enum.map(shown, &elem(&1, 0))
      assert StopReason.classify(143, lines, "grok").category == :killed
      assert StopReason.classify(130, lines, "grok").category == :killed
      assert StopReason.classify(0, lines, "grok").category == :exited_without_done
    end
  end
end
