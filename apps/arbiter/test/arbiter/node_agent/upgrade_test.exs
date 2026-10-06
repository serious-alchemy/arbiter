defmodule Arbiter.NodeAgent.UpgradeTest do
  @moduledoc """
  Self-upgrade on version skew (docs/design/remote-workers.md §6): download,
  sha256-verify, unpack beside the running release, then flip the atomic
  `current` symlink and exit so systemd starts the new one.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Upgrade

  @credential "arbn_node123." <> String.duplicate("A", 52)

  setup context do
    home = Path.join(System.tmp_dir!(), "arb-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "releases/1.0.0/bin"))
    File.write!(Path.join(home, "releases/1.0.0/bin/arbiter"), "old")
    File.ln_s!("releases/1.0.0", Path.join(home, "current"))
    on_exit(fn -> File.rm_rf!(home) end)

    stub = :"upgrade_stub_#{System.unique_integer([:positive])}"
    test_pid = self()

    config = %Config{
      primary_url: "https://primary.example.ts.net",
      node_home: home,
      credential: @credential,
      node_id: "node123",
      version: "1.0.0",
      req_options: [plug: {Req.Test, stub}, retry: false],
      idle_poll_ms: 5,
      halt_fun: fn -> send(test_pid, :halted) end,
      live_runs_fun: fn -> [] end
    }

    %{home: home, config: config, stub: stub, tags: context}
  end

  # A release tarball shaped like the published one: a single top-level
  # `arbiter/` dir holding bin/, lib/, …
  defp tarball(version, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "arb-tar-src-#{System.unique_integer([:positive])}")
    root = Path.join(dir, Keyword.get(opts, :root, "arbiter"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "bin/arbiter"), "#!/bin/sh\necho #{version}\n")
    File.chmod!(Path.join(root, "bin/arbiter"), 0o755)
    File.mkdir_p!(Path.join(root, "releases"))
    File.write!(Path.join(root, "releases/START_ERL.data"), version)
    out = dir <> ".tar.gz"

    files =
      for rel <- ["bin/arbiter", "releases/START_ERL.data"],
          do:
            {String.to_charlist(Path.join(Path.basename(root), rel)),
             String.to_charlist(Path.join(root, rel))}

    :ok = :erl_tar.create(String.to_charlist(out), files, [:compressed])
    File.rm_rf!(dir)
    body = File.read!(out)
    File.rm!(out)
    body
  end

  defp sha(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp serve(stub, body, status \\ 200) do
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      send(
        test_pid,
        {:request, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  describe "prepare/2" do
    test "downloads with the node credential, verifies the sha256 and unpacks to releases/<v>",
         ctx do
      body = tarball("2.0.0")
      serve(ctx.stub, body)

      assert {:ok, dir} =
               Upgrade.prepare(ctx.config, %{"version" => "2.0.0", "sha256" => sha(body)})

      assert dir == Path.join(ctx.home, "releases/2.0.0")
      assert File.read!(Path.join(dir, "bin/arbiter")) =~ "echo 2.0.0"
      assert File.stat!(Path.join(dir, "bin/arbiter")).mode |> Bitwise.band(0o111) != 0

      assert_received {:request, "GET", "/nodes/agent/2.0.0.tar.gz", ["Bearer " <> @credential]}
      refute File.exists?(Path.join(ctx.home, "releases/2.0.0.tar.gz.part"))
      # the running release is untouched
      assert File.read!(Path.join(ctx.home, "releases/1.0.0/bin/arbiter")) == "old"
    end

    test "a checksum mismatch is refused and leaves nothing behind", ctx do
      serve(ctx.stub, tarball("2.0.0"))

      assert {:error, :sha256_mismatch} =
               Upgrade.prepare(ctx.config, %{
                 "version" => "2.0.0",
                 "sha256" => String.duplicate("0", 64)
               })

      refute File.exists?(Path.join(ctx.home, "releases/2.0.0"))
      assert Path.wildcard(Path.join(ctx.home, "releases/*2.0.0*")) == []
    end

    test "an HTTP error is an error, not a crash", ctx do
      serve(ctx.stub, "nope", 401)

      assert {:error, {:http, 401}} =
               Upgrade.prepare(ctx.config, %{
                 "version" => "2.0.0",
                 "sha256" => String.duplicate("0", 64)
               })
    end

    test "a tarball without bin/arbiter is not a release", ctx do
      empty =
        (fn ->
           dir = Path.join(System.tmp_dir!(), "arb-empty-#{System.unique_integer([:positive])}")
           File.mkdir_p!(dir)
           File.write!(Path.join(dir, "README"), "x")
           out = dir <> ".tar.gz"

           :ok =
             :erl_tar.create(
               String.to_charlist(out),
               [{~c"README", String.to_charlist(Path.join(dir, "README"))}],
               [:compressed]
             )

           body = File.read!(out)
           File.rm_rf!(dir)
           File.rm!(out)
           body
         end).()

      serve(ctx.stub, empty)

      assert {:error, :not_a_release} =
               Upgrade.prepare(ctx.config, %{"version" => "3.0.0", "sha256" => sha(empty)})

      refute File.exists?(Path.join(ctx.home, "releases/3.0.0"))
    end

    test "a version that could escape the releases dir is refused before any request", ctx do
      serve(ctx.stub, "x")

      for bad <- ["../evil", "1.0/../../x", "", "a b", "/abs", ".hidden"] do
        assert {:error, {:bad_version, ^bad}} =
                 Upgrade.prepare(ctx.config, %{
                   "version" => bad,
                   "sha256" => String.duplicate("0", 64)
                 })
      end

      refute_received {:request, _, _, _}
    end

    test "a malformed sha256 is refused", ctx do
      assert {:error, :bad_sha256} =
               Upgrade.prepare(ctx.config, %{"version" => "2.0.0", "sha256" => "abc"})
    end

    test "an archive member that climbs out of the staging dir is refused", ctx do
      dir = Path.join(System.tmp_dir!(), "arb-evil-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "f"), "x")
      out = dir <> ".tar.gz"

      :ok =
        :erl_tar.create(
          String.to_charlist(out),
          [{~c"../escaped", String.to_charlist(Path.join(dir, "f"))}],
          [:compressed]
        )

      body = File.read!(out)
      File.rm_rf!(dir)
      File.rm!(out)
      serve(ctx.stub, body)

      assert {:error, _} =
               Upgrade.prepare(ctx.config, %{"version" => "2.0.0", "sha256" => sha(body)})

      refute File.exists?(Path.join(ctx.home, "escaped"))
      refute File.exists?(Path.join(ctx.home, "releases/escaped"))
    end

    test "an already-unpacked release is not downloaded again", ctx do
      body = tarball("2.0.0")
      serve(ctx.stub, body)
      spec = %{"version" => "2.0.0", "sha256" => sha(body)}

      {:ok, _} = Upgrade.prepare(ctx.config, spec)
      assert_received {:request, _, _, _}
      {:ok, _} = Upgrade.prepare(ctx.config, spec)
      refute_received {:request, _, _, _}
    end
  end

  describe "commit/3" do
    setup ctx do
      body = tarball("2.0.0")
      serve(ctx.stub, body)
      {:ok, _} = Upgrade.prepare(ctx.config, %{"version" => "2.0.0", "sha256" => sha(body)})
      :ok
    end

    test "records upgrade.pending, flips current atomically and halts", ctx do
      assert :ok = Upgrade.commit(ctx.config, "2.0.0")

      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/2.0.0"
      assert_received :halted

      pending = File.read!(Path.join(ctx.home, "upgrade.pending"))
      assert pending =~ "from=releases/1.0.0\n"
      assert pending =~ "to=2.0.0\n"
      assert pending =~ ~r/at=\d+\n/
    end

    test "waits for the node to be idle before flipping", ctx do
      {:ok, runs} = Agent.start_link(fn -> [%{"id" => "run-1"}] end)
      config = %{ctx.config | live_runs_fun: fn -> Agent.get(runs, & &1) end}

      task = Task.async(fn -> Upgrade.commit(config, "2.0.0") end)

      refute Task.yield(task, 50)
      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/1.0.0"
      refute_received :halted

      Agent.update(runs, fn _ -> [] end)
      assert :ok = Task.await(task)
      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/2.0.0"
    end

    test "refuses to flip to a release that was never prepared", ctx do
      assert {:error, :not_prepared} = Upgrade.commit(ctx.config, "9.9.9")
      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/1.0.0"
      refute_received :halted
    end
  end

  describe "confirm/2" do
    test "the new release writes `confirmed` and clears upgrade.pending", ctx do
      File.write!(Path.join(ctx.home, "upgrade.pending"), "from=releases/1.0.0\nto=2.0.0\nat=1\n")

      assert :confirmed = Upgrade.confirm(%{ctx.config | version: "2.0.0"})
      assert File.exists?(Path.join(ctx.home, "confirmed"))
      refute File.exists?(Path.join(ctx.home, "upgrade.pending"))
    end

    test "is a no-op when no upgrade is pending, or it is for another version", ctx do
      assert :none = Upgrade.confirm(ctx.config)
      File.write!(Path.join(ctx.home, "upgrade.pending"), "from=a\nto=3.0.0\nat=1\n")
      assert :none = Upgrade.confirm(ctx.config)
      assert File.exists?(Path.join(ctx.home, "upgrade.pending"))
    end

    test "prunes releases beyond the running one and its predecessor", ctx do
      for v <- ["0.8.0", "0.9.0", "2.0.0"] do
        File.mkdir_p!(Path.join(ctx.home, "releases/#{v}/bin"))
      end

      File.rm!(Path.join(ctx.home, "current"))
      File.ln_s!("releases/2.0.0", Path.join(ctx.home, "current"))
      File.write!(Path.join(ctx.home, "upgrade.pending"), "from=releases/1.0.0\nto=2.0.0\nat=1\n")

      assert :confirmed = Upgrade.confirm(%{ctx.config | version: "2.0.0"})

      assert Enum.sort(File.ls!(Path.join(ctx.home, "releases"))) == ["1.0.0", "2.0.0"]
    end
  end
end
