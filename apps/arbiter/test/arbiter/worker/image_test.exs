defmodule Arbiter.Worker.ImageTest do
  @moduledoc """
  bd-9r5jdt (P4): the worker image plan: where the Containerfile comes from
  (the default branch's committed tree, never a worker's branch), digest
  pinning, content-hash tags, and the list / prune halves of the lifecycle.
  Every podman call goes through `:runner`, so this runs without podman.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image

  @digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)

  defp resolver(digest \\ @digest), do: fn _ref -> {:ok, "sha256:" <> digest} end

  # Answers only for the shared base's FROMs (the OS and arb's Erlang runtime);
  # any other ref goes to `other`.
  defp base_only(other \\ fn ref -> flunk("resolver asked for #{ref}") end) do
    fn
      "docker.io/library/debian:trixie-slim" -> {:ok, "sha256:" <> @digest}
      "docker.io/library/erlang:" <> _ -> {:ok, "sha256:" <> @digest}
      ref -> other.(ref)
    end
  end

  defp opts(extra \\ []), do: Keyword.merge([resolver: resolver()], extra)

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

  defp tmp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "image-#{label}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A repo whose default branch is `main`, with `.arbiter/Containerfile` =
  # `files[".arbiter/Containerfile"]` etc. committed on it.
  defp repo_with(files) do
    dir = tmp_dir("repo")
    git!(dir, ["init", "-q", "-b", "main"])
    commit_files(dir, files, "init")
    dir
  end

  defp commit_files(dir, files, msg) do
    Enum.each(files, fn {path, body} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", msg])
  end

  @repo_containerfile """
  FROM ${ARBITER_BASE}
  RUN echo default-branch-toolchain
  """

  describe "plan/3: the base layer carries the k8s pod runtime (K7, bd-dzyclc)" do
    setup do
      repo = repo_with(%{"README.md" => "hi\n"})
      {:ok, plan} = Image.plan(repo, "main", opts())
      %{base: plan.base.containerfile}
    end

    test "tini is installed and the arbiter user is uid/gid 10001 with a passwd entry", %{
      base: base
    } do
      assert base =~ ~r/openssh-client procps socat sqlite3 tini tmux/
      assert base =~ "groupadd --gid 10001 arbiter"
      assert base =~ ~r/useradd --uid 10001 --gid 10001 --no-log-init --create-home/
      assert base =~ "--home-dir /home/arbiter"
      # the base never switches user: a local podman worker keeps `--userns=keep-id`
      refute base =~ ~r/^USER\b/m
    end

    test "the base carries the runtime-contract label a prebuilt image inherits (KH14)", %{
      base: base
    } do
      assert base =~ ~s(LABEL arbiter.runtime-contract="1")
      assert Arbiter.Worker.Image.contract_label() == {"arbiter.runtime-contract", "1"}
    end

    test "seed and snapshotter are baked into /opt/arbiter/bin, byte for byte, root-owned", %{
      base: base
    } do
      for {name, text} <- Arbiter.NodeAgent.K8s.PodScripts.bin() do
        [_, b64] =
          Regex.run(~r/printf '%s' '([^']*)' \| base64 -d > \/opt\/arbiter\/bin\/#{name}\b/, base)

        assert Base.decode64!(String.replace(b64, "\\\n", "")) == text
        assert base =~ "chmod 0755 /opt/arbiter/bin/#{name}"
      end

      # `PATH` still starts with the CLI dir, and nothing after it changes ownership
      assert base =~ "ENV PATH=/opt/arbiter/cli:$PATH"
      refute base =~ "chown"
    end

    test "the install RUN, run by a shell as the Containerfile parser hands it over, writes them",
         %{base: base} do
      [run] = Regex.run(~r/^RUN mkdir -p \/opt\/arbiter\/bin.*?(?=\nENV |\z)/ms, base)
      command = run |> String.replace_prefix("RUN ", "") |> String.replace("\\\n", "")
      # a plain path: the test's own tmp_dir name has parentheses in it
      out = Path.join(System.tmp_dir!(), "k7-bin-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)
      command = String.replace(command, "/opt/arbiter/bin", out)

      assert {"", 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)

      for {name, text} <- Arbiter.NodeAgent.K8s.PodScripts.bin() do
        assert File.read!(Path.join(out, name)) == text
        assert File.stat!(Path.join(out, name)).mode |> Bitwise.band(0o777) == 0o755
      end
    end

    test "the base is repo-independent: any repo gets the same base tag" do
      assert Image.plan(repo_with(%{"a" => "1"}), "main", opts())
             |> elem(1)
             |> then(& &1.base.hash) ==
               Image.plan(repo_with(%{"a" => "2"}), "main", opts())
               |> elem(1)
               |> then(& &1.base.hash)
    end
  end

  # bd-59m96o: an arb compiled on OTP 29 cannot load on a repo image's OTP 27
  # ("corrupt atom table"), so the base carries an Erlang for arb alone.
  describe "plan/3: the base carries the Erlang/OTP arb runs on (bd-59m96o)" do
    test "the arb runtime is the official Erlang image of arb's release, pinned, off PATH" do
      repo = repo_with(%{"README.md" => "hi\n"})
      assert {:ok, plan} = Image.plan(repo, "main", opts(arb_otp: "29"))
      base = plan.base.containerfile

      assert base =~ "FROM docker.io/library/erlang:29-slim@sha256:#{@digest} AS arb_otp"
      assert base =~ "COPY --from=arb_otp /usr/local/lib/erlang /opt/arbiter/otp"
      assert base =~ ~s(LABEL arbiter.arb-otp="29")
      assert {"docker.io/library/erlang:29-slim", "sha256:" <> @digest} in plan.pins

      # The OS stage is still the last one, and PATH still names only the CLI
      # dir: the repo's own Erlang stays the one its toolchain layer installs.
      assert [_, os_stage] = String.split(base, ~r/^FROM /m, parts: 3) |> Enum.drop(1)
      assert os_stage =~ ~r/\Adocker\.io\/library\/debian:trixie-slim@/
      assert base =~ "ENV PATH=/opt/arbiter/cli:$PATH"
      refute base =~ ~r/^ENV PATH=.*\/opt\/arbiter\/otp/m
    end

    test "a repo pinned to an older Erlang keeps it, and gets the arb runtime beside it" do
      repo = repo_with(%{".tool-versions" => "erlang 27.1.2\nelixir 1.17.3-otp-27\n"})
      assert {:ok, plan} = Image.plan(repo, "main", opts(arb_otp: "29"))

      assert plan.toolchain.erlang == "27.1.2"
      assert plan.containerfile =~ "elixir:1.17.3-otp-27-slim"
      assert plan.base.containerfile =~ "erlang:29-slim"
      # The toolchain layer copies /usr/local only: it cannot reach /opt/arbiter/otp.
      refute plan.containerfile =~ "/opt/arbiter"
    end

    test "another arb release is another base, and so another image" do
      repo = repo_with(%{"README.md" => "hi\n"})
      {:ok, a} = Image.plan(repo, "main", opts(arb_otp: "29"))
      {:ok, b} = Image.plan(repo, "main", opts(arb_otp: "30"))

      refute a.base.tag == b.base.tag
      refute a.tag == b.tag
    end

    test "by default the runtime is the release the host's arb was built on" do
      dir = tmp_dir("arb")
      stamped = Arbiter.Test.ArbEscriptFixture.build!(dir, stamp: "31", name: "arb")
      unstamped = Arbiter.Test.ArbEscriptFixture.build!(dir, stamp: nil, name: "old-arb")
      repo = repo_with(%{"README.md" => "hi\n"})

      assert {:ok, plan} = Image.plan(repo, "main", opts(arb_path: stamped))
      assert plan.base.containerfile =~ "FROM docker.io/library/erlang:31-slim@"

      assert {:ok, plan} = Image.plan(repo, "main", opts(arb_path: unstamped))

      assert plan.base.containerfile =~
               "FROM docker.io/library/erlang:#{System.otp_release()}-slim@"
    end

    test "the runtime keeps what the VM loads and drops sources, headers and docs" do
      repo = repo_with(%{"README.md" => "hi\n"})
      {:ok, plan} = Image.plan(repo, "main", opts(arb_otp: "29"))
      [run] = Regex.run(~r/^RUN find \/usr\/local\/lib\/erlang .*$/m, plan.base.containerfile)

      root = tmp_dir("otp")

      kept =
        ~w(bin/erl erts-1.0/bin/beam.smp lib/stdlib-1.0/ebin/lists.beam lib/crypto-1.0/priv/lib/crypto.so releases/29/OTP_VERSION)

      dropped =
        ~w(lib/stdlib-1.0/src/lists.erl lib/stdlib-1.0/include/ms_transform.hrl erts-1.0/include/erl_nif.h lib/stdlib-1.0/doc/chunks/lists.chunk lib/crypto-1.0/c_src/crypto.c lib/ssl-1.0/examples/certs/x.pem)

      for rel <- kept ++ dropped do
        File.mkdir_p!(Path.dirname(Path.join(root, rel)))
        File.write!(Path.join(root, rel), "x")
      end

      command =
        run
        |> String.replace_prefix("RUN ", "")
        |> String.replace("/usr/local/lib/erlang", root)

      assert {"", 0} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)

      for rel <- kept, do: assert(File.exists?(Path.join(root, rel)), "#{rel} was removed")
      for rel <- dropped, do: refute(File.exists?(Path.join(root, rel)), "#{rel} was kept")
    end
  end

  describe "plan/3: the Containerfile comes from the default branch only" do
    test "a Containerfile committed on a worker branch is never read" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})

      git!(repo, ["checkout", "-q", "-b", "worker/evil"])

      commit_files(
        repo,
        %{".arbiter/Containerfile" => "FROM ${ARBITER_BASE}\nRUN echo worker-branch-payload\n"},
        "evil"
      )

      # ... and the checked-out working tree is the worker's too.
      File.write!(
        Path.join(repo, ".arbiter/Containerfile"),
        "FROM ${ARBITER_BASE}\nRUN echo uncommitted-payload\n"
      )

      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.containerfile =~ "default-branch-toolchain"
      refute plan.containerfile =~ "worker-branch-payload"
      refute plan.containerfile =~ "uncommitted-payload"
      assert plan.source == :repo
      assert plan.ref == "refs/heads/main"
    end

    test "a branch that has the file while the default branch does not gets the generated default" do
      repo = repo_with(%{"README.md" => "hi\n"})
      git!(repo, ["checkout", "-q", "-b", "worker/evil"])

      commit_files(
        repo,
        %{".arbiter/Containerfile" => "FROM ${ARBITER_BASE}\nRUN echo worker-branch-payload\n"},
        "evil"
      )

      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.source == :generated
      refute plan.containerfile =~ "worker-branch-payload"
    end

    test "prefers origin/<default> over a local default branch that is ahead of it" do
      origin = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      clone = Path.join(tmp_dir("clone"), "c")
      git!(origin, ["clone", "-q", origin, clone])

      commit_files(
        clone,
        %{".arbiter/Containerfile" => "FROM ${ARBITER_BASE}\nRUN echo unpushed-local\n"},
        "local only"
      )

      assert {:ok, plan} = Image.plan(clone, "main", opts())
      assert plan.containerfile =~ "default-branch-toolchain"
      refute plan.containerfile =~ "unpushed-local"
      assert plan.ref == "refs/remotes/origin/main"
    end

    test "refuses a default branch that is not a plain branch name" do
      repo = repo_with(%{"README.md" => "hi\n"})

      for bad <- ["--upload-pack=x", "main:other", "a b", "", "../x", "HEAD~1"] do
        assert {:error, {:bad_branch, ^bad}} = Image.plan(repo, bad, opts())
      end
    end

    test "an unknown default branch is an error, not a fallback to HEAD" do
      repo = repo_with(%{"README.md" => "hi\n"})
      git!(repo, ["checkout", "-q", "-b", "worker/x"])
      assert {:error, {:no_default_branch, "trunk"}} = Image.plan(repo, "trunk", opts())
    end
  end

  describe "plan/3: toolchain and generated default" do
    test "the toolchain tuple comes from .tool-versions on the default branch" do
      repo =
        repo_with(%{".tool-versions" => "erlang 27.1.2\nelixir 1.17.3-otp-27\nnodejs 20.11.0\n"})

      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.toolchain == %{erlang: "27.1.2", elixir: "1.17.3", node: "20.11.0"}
      assert plan.name == "beam-1.17.3-27.1.2-node20.11.0"
      assert plan.containerfile =~ "docker.io/library/elixir:1.17.3-otp-27-slim@sha256:"
      assert plan.containerfile =~ "docker.io/library/node:20.11.0-bookworm-slim@sha256:"
    end

    test "a pin that is not a plain version is refused, never replaced by the default" do
      repo = repo_with(%{".tool-versions" => "erlang 29.1.1\nelixir latest\n"})
      assert {:error, {:unsupported_pin, "elixir", "latest"}} = Image.plan(repo, "main", opts())
    end

    test "a Containerfile whose Elixir image is not the pinned runtime is refused" do
      repo =
        repo_with(%{
          ".tool-versions" => "erlang 29.1.1\nelixir 1.20.4-otp-29\n",
          ".arbiter/Containerfile" =>
            "FROM docker.io/hexpm/elixir:1.19.4-erlang-28.2-debian-bookworm-20240904\n"
        })

      assert {:error, {:containerfile_pin_mismatch, message}} =
               Image.plan(repo, "main", opts(source: :containerfile))

      assert message =~ "1.19.4"
    end

    test "falls back to the configured defaults when there is no pin file" do
      repo = repo_with(%{"README.md" => "hi\n"})

      assert {:ok, plan} =
               Image.plan(repo, "main", opts(defaults: %{erlang: "28.2", elixir: "1.19.4"}))

      assert plan.toolchain == %{erlang: "28.2", elixir: "1.19.4", node: nil}
      assert plan.name == "beam-1.19.4-28.2"
      assert plan.containerfile =~ "elixir:1.19.4-otp-28-slim@sha256:"
      refute plan.containerfile =~ "library/node"
    end

    test "two repos with the same toolchain share one image tag" do
      a = repo_with(%{".tool-versions" => "erlang 28.2\nelixir 1.19.4\n"})
      b = repo_with(%{".tool-versions" => "erlang 28.2\nelixir 1.19.4\n", "x" => "y"})
      assert {:ok, pa} = Image.plan(a, "main", opts())
      assert {:ok, pb} = Image.plan(b, "main", opts())
      assert pa.tag == pb.tag
    end

    test "the generated default is toolchain only: FROM base, no context copy" do
      repo = repo_with(%{"README.md" => "hi\n"})
      assert {:ok, plan} = Image.plan(repo, "main", opts())
      refute plan.containerfile =~ ~r/^\s*(COPY|ADD)\s+(?!--from=)/m
      assert plan.containerfile =~ "FROM ${ARBITER_BASE}"
    end

    test "the generated toolchain installs Hex and rebar into a MIX_HOME outside any checkout" do
      repo = repo_with(%{"README.md" => "hi\n"})
      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.containerfile =~ "ENV MIX_HOME=/opt/toolchain/mix HEX_HOME=/opt/toolchain/hex"
      assert plan.containerfile =~ "mix local.hex --force"
      assert plan.containerfile =~ "mix local.rebar --force"
    end

    test "a repo Containerfile gets a per-repo image name, a generated one a toolchain name" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      assert {:ok, plan} = Image.plan(repo, "main", opts(repo_name: "My_Repo"))
      assert plan.name == "repo-my-repo"
    end
  end

  describe "plan/3: the source option (KH11)" do
    test "containerfile refuses a repo with no .arbiter/Containerfile on the default branch" do
      repo = repo_with(%{"README.md" => "hi\n"})

      assert {:error, {:source_unavailable, :containerfile, _}} =
               Image.plan(repo, "main", opts(source: :containerfile))
    end

    test "containerfile plans the committed Containerfile" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      assert {:ok, plan} = Image.plan(repo, "main", opts(source: :containerfile))
      assert plan.source == :repo
    end

    test "generated ignores the repo's Containerfile" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      assert {:ok, plan} = Image.plan(repo, "main", opts(source: :generated))
      assert plan.source == :generated
      refute plan.containerfile =~ "default-branch-toolchain"
    end

    test "auto (and no option) is today: the Containerfile when committed, else generated" do
      with_cf = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      without = repo_with(%{"README.md" => "hi\n"})

      for source <- [nil, :auto] do
        o = opts(if(source, do: [source: source], else: []))
        assert {:ok, %{source: :repo}} = Image.plan(with_cf, "main", o)
        assert {:ok, %{source: :generated}} = Image.plan(without, "main", o)
      end
    end

    test "prebuilt without an image.ref is unavailable (Prebuilt plans it, KH14)" do
      repo = repo_with(%{"README.md" => "hi\n"})

      assert {:error, {:source_unavailable, :prebuilt, _}} =
               Image.plan(repo, "main", opts(source: :prebuilt))
    end
  end

  describe "plan/3: base images are pinned by digest" do
    test "an unpinned FROM is rewritten to ref@sha256 through the resolver" do
      repo =
        repo_with(%{
          ".arbiter/Containerfile" =>
            "FROM docker.io/library/debian:12 AS build\nFROM ${ARBITER_BASE}\nCOPY --from=build /x /x\n"
        })

      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.containerfile =~ "FROM docker.io/library/debian:12@sha256:#{@digest} AS build"
      assert plan.containerfile =~ "FROM ${ARBITER_BASE}\n"
      assert {"docker.io/library/debian:12", "sha256:" <> @digest} in plan.pins
    end

    test "an already pinned FROM is kept and the resolver is not asked" do
      pinned = "docker.io/library/debian@sha256:#{@other_digest}"
      repo = repo_with(%{".arbiter/Containerfile" => "FROM #{pinned}\n"})

      assert {:ok, plan} =
               Image.plan(repo, "main", resolver: base_only())

      assert plan.containerfile =~ "FROM #{pinned}\n"
    end

    test "a stage alias and scratch need no pin" do
      repo =
        repo_with(%{
          ".arbiter/Containerfile" =>
            "FROM scratch AS empty\nFROM ${ARBITER_BASE} AS final\nFROM final\n"
        })

      assert {:ok, _plan} =
               Image.plan(repo, "main", resolver: base_only())
    end

    test "a FROM that cannot be resolved refuses the build" do
      repo = repo_with(%{".arbiter/Containerfile" => "FROM docker.io/library/debian:12\n"})

      assert {:error, {:unpinned_base, "docker.io/library/debian:12", :offline}} =
               Image.plan(repo, "main", resolver: base_only(fn _ -> {:error, :offline} end))
    end

    test "a FROM through any build arg other than ARBITER_BASE is refused" do
      repo =
        repo_with(%{".arbiter/Containerfile" => "ARG IMG=evil.example/x:1\nFROM ${IMG}\n"})

      assert {:error, {:unpinned_base, "${IMG}", :build_arg}} =
               Image.plan(repo, "main", opts())
    end

    test "a repo Containerfile with no FROM at all is refused" do
      repo = repo_with(%{".arbiter/Containerfile" => "RUN echo hi\n"})
      assert {:error, :no_from} = Image.plan(repo, "main", opts())
    end

    test "the shared base image is pinned too" do
      repo = repo_with(%{"README.md" => "hi\n"})
      assert {:ok, plan} = Image.plan(repo, "main", opts())
      assert plan.base.containerfile =~ "FROM docker.io/library/debian:trixie-slim@sha256:"
      assert plan.base.tag =~ ~r|^localhost/arbiter-dev/base:[0-9a-f]{12}$|
      assert plan.build_args == [{"ARBITER_BASE", plan.base.tag}]
    end
  end

  describe "plan/3: tags are content hashes" do
    test "shape, and the same inputs give the same tag" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      assert {:ok, a} = Image.plan(repo, "main", opts(repo_name: "r"))
      assert {:ok, b} = Image.plan(repo, "main", opts(repo_name: "r"))
      assert a.tag =~ ~r|^localhost/arbiter-dev/repo-r:[0-9a-f]{12}$|
      assert a.tag == b.tag
      assert a.hash == b.hash
    end

    test "a changed Containerfile changes the tag" do
      repo = repo_with(%{".arbiter/Containerfile" => @repo_containerfile})
      {:ok, a} = Image.plan(repo, "main", opts(repo_name: "r"))
      commit_files(repo, %{".arbiter/Containerfile" => @repo_containerfile <> "RUN true\n"}, "v2")
      {:ok, b} = Image.plan(repo, "main", opts(repo_name: "r"))
      refute a.tag == b.tag
    end

    test "a changed pin file changes the tag" do
      repo = repo_with(%{".tool-versions" => "erlang 28.2\nelixir 1.19.4\n"})
      {:ok, a} = Image.plan(repo, "main", opts())
      commit_files(repo, %{".tool-versions" => "erlang 28.2\nelixir 1.19.5\n"}, "bump")
      {:ok, b} = Image.plan(repo, "main", opts())
      refute a.tag == b.tag
    end

    test "a moved base digest changes both the base tag and the toolchain tag" do
      repo = repo_with(%{"README.md" => "hi\n"})
      {:ok, a} = Image.plan(repo, "main", resolver: resolver(@digest))
      {:ok, b} = Image.plan(repo, "main", resolver: resolver(@other_digest))
      refute a.base.tag == b.base.tag
      refute a.tag == b.tag
    end

    test "an unrelated lockfile or source change does not change the tag" do
      repo = repo_with(%{"mix.lock" => "%{}\n"})
      {:ok, a} = Image.plan(repo, "main", opts())
      commit_files(repo, %{"mix.lock" => "%{a: 1}\n", "lib/x.ex" => "x\n"}, "deps")
      {:ok, b} = Image.plan(repo, "main", opts())
      assert a.tag == b.tag
    end
  end

  describe "list/1 and prune/1" do
    defp image(tag, created, extra \\ %{}) do
      Map.merge(
        %{
          "Id" => "id-" <> tag,
          "Names" => [tag],
          "Created" => created,
          "Size" => 1000,
          "Labels" => %{"arbiter.dev-image" => "1"}
        },
        extra
      )
    end

    defp stub_images(images, test_pid) do
      fn "podman", args, _opts ->
        send(test_pid, {:podman, args})

        case args do
          ["images" | _] -> {Jason.encode!(images), 0}
          ["rmi" | _] -> {"", 0}
        end
      end
    end

    test "list/1 returns only Arbiter's images, newest first" do
      images = [
        image("localhost/arbiter-dev/beam-1.19.4-28.2:aaaaaaaaaaaa", 100),
        image("localhost/arbiter-dev/base:bbbbbbbbbbbb", 300),
        image("localhost/arbiter-dev/beam-1.19.4-28.2:cccccccccccc", 200),
        image("docker.io/library/debian:12", 999, %{"Labels" => %{}})
      ]

      assert {:ok, listed} = Image.list(runner: stub_images(images, self()))

      assert Enum.map(listed, & &1.tag) |> Enum.sort() ==
               Enum.sort(Enum.map(Enum.take(images, 3), &hd(&1["Names"])))

      assert [%{name: "base", kind: :base, hash: "bbbbbbbbbbbb"} | _] = listed
      assert_received {:podman, ["images" | rest]}
      assert "label=arbiter.dev-image" in rest
    end

    test "prune/1 keeps the newest two tags per name and removes the rest" do
      images =
        for {h, t} <- [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}] do
          image("localhost/arbiter-dev/beam-1.19.4-28.2:#{String.duplicate(h, 12)}", t)
        end ++ [image("localhost/arbiter-dev/base:#{String.duplicate("e", 12)}", 1)]

      assert {:ok, %{removed: removed, failed: []}} =
               Image.prune(runner: stub_images(images, self()))

      assert Enum.sort(removed) ==
               Enum.sort([
                 "localhost/arbiter-dev/beam-1.19.4-28.2:#{String.duplicate("a", 12)}",
                 "localhost/arbiter-dev/beam-1.19.4-28.2:#{String.duplicate("b", 12)}"
               ])

      assert_received {:podman, ["rmi", _tag]}
      refute_received {:podman, ["rmi", "localhost/arbiter-dev/base:" <> _]}
    end

    test "prune/1 never forces removal and never names a non-Arbiter image" do
      images = [
        image("localhost/arbiter-dev/x:aaaaaaaaaaaa", 1),
        image("localhost/arbiter-dev/x:bbbbbbbbbbbb", 2),
        image("localhost/arbiter-dev/x:cccccccccccc", 3),
        image("docker.io/library/debian:12", 0, %{"Labels" => %{}})
      ]

      assert {:ok, _} = Image.prune(runner: stub_images(images, self()))
      assert_received {:podman, ["rmi", "localhost/arbiter-dev/x:aaaaaaaaaaaa"]}
      refute_received {:podman, ["rmi", "docker.io" <> _]}
      refute_received {:podman, ["rmi", "--force" | _]}
    end

    test "prune/1 reports an image podman refuses to remove (in use) instead of failing" do
      images =
        for {h, t} <- [{"a", 1}, {"b", 2}, {"c", 3}],
            do: image("localhost/arbiter-dev/x:#{String.duplicate(h, 12)}", t)

      runner = fn
        "podman", ["images" | _], _ -> {Jason.encode!(images), 0}
        "podman", ["rmi", _], _ -> {"image is in use by a container", 2}
      end

      assert {:ok, %{removed: [], failed: [{tag, _}]}} = Image.prune(runner: runner)
      assert tag =~ "aaaaaaaaaaaa"
    end

    test "prune/1 honours :keep_tags" do
      images =
        for {h, t} <- [{"a", 1}, {"b", 2}, {"c", 3}],
            do: image("localhost/arbiter-dev/x:#{String.duplicate(h, 12)}", t)

      keep = "localhost/arbiter-dev/x:#{String.duplicate("a", 12)}"

      assert {:ok, %{removed: []}} =
               Image.prune(runner: stub_images(images, self()), keep_tags: [keep], keep: 2)
    end
  end
end
