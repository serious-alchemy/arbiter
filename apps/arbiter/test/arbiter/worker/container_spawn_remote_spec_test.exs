defmodule Arbiter.Worker.ContainerSpawnRemoteSpecTest do
  @moduledoc "RW12: the remote run spec carries the install id the node reaps by (§10.6)."
  use ExUnit.Case, async: false

  alias Arbiter.Nodes.InstallId
  alias Arbiter.Worker.ContainerSpawn

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, Path.join(dir, "data"))

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :data_dir, v)
        :error -> Application.delete_env(:arbiter, :data_dir)
      end
    end)

    proxy = Path.join(dir, "proxy.sock")
    File.write!(proxy, "")

    request = %{
      name: "arb-t-1",
      image: %{tag: "localhost/x:1", plan: nil},
      worktree: "/work/tree",
      home: "/work/home",
      config_dir: "/work/config",
      config_files: %{},
      tmp_dir: "/work/tmp",
      cli: [],
      prompt_paths: [],
      network: [proxy_socket: proxy, socat: "socat"],
      env: [],
      services: [],
      limits: %{},
      checkout: nil,
      task_id: "bd-t"
    }

    %{request: request}
  end

  test "the spec names the install", %{request: request} do
    assert {:ok, spec} =
             ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")

    assert spec["install"] == InstallId.get()
  end

  test "a registry request puts the digest-pinned ref in the spec image (A2)", %{request: request} do
    ref = "registry.example.com/arbiter/worker@sha256:" <> String.duplicate("b", 64)
    request = put_in(request.image, %{tag: "localhost/x:1", plan: nil, ref: ref})

    assert {:ok, spec} =
             ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")

    assert spec["image"] == %{"tag" => "localhost/x:1", "plan" => nil, "ref" => ref}
  end

  test "no ref, no ref key: a build node's spec is unchanged", %{request: request} do
    assert {:ok, spec} =
             ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")

    assert spec["image"] == %{"tag" => "localhost/x:1", "plan" => nil}
  end

  describe "worktree files and host paths (bd-8y8ztm)" do
    alias Arbiter.Agents.{Claude, SecurityPolicy}
    alias Arbiter.MCP.AgentConfig

    # The real argv the dispatcher builds for a podman-sandboxed Claude run that
    # was handed an injected `.mcp.json` (the shape that crashed the RW13 canary).
    defp real_argv(mcp_config) do
      policy =
        SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

      {:ok, argv} =
        Claude.default_argv("do the thing",
          security: policy,
          sandbox_wrap: true,
          mcp_config: mcp_config
        )

      argv
    end

    defp injected_worktree(dir) do
      worktree = Path.join(dir, "wt")
      File.mkdir_p!(Path.join(worktree, ".claude/skills/tdd"))
      File.write!(Path.join(worktree, ".claude/skills/tdd/SKILL.md"), "# tdd")

      :ok =
        AgentConfig.Claude.write_mcp_config(worktree,
          mcp_url: "http://127.0.0.1:4848/mcp",
          scope_token: "scope-token-xyz",
          server_name: "arbiter"
        )

      worktree
    end

    test "worktree_files/1 ships .mcp.json with the token swapped for an env reference", %{
      tmp_dir: dir
    } do
      worktree = injected_worktree(dir)

      assert {:ok, files, secrets} = ContainerSpawn.worktree_files(worktree)

      assert secrets == %{"ARBITER_MCP_TOKEN" => "scope-token-xyz"}
      refute files[".mcp.json"] =~ "scope-token-xyz"

      assert %{"mcpServers" => %{"arbiter" => %{"headers" => %{"Authorization" => auth}}}} =
               Jason.decode!(files[".mcp.json"])

      assert auth == "Bearer ${ARBITER_MCP_TOKEN}"
      assert files[".claude/skills/tdd/SKILL.md"] == "# tdd"
    end

    test "worktree_files/1 of a worktree with nothing injected is empty", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "bare"))
      assert {:ok, %{}, %{}} = ContainerSpawn.worktree_files(Path.join(dir, "bare"))
    end

    test "the spec carries the files on the worktree mount and the token as a secret", %{
      request: request,
      tmp_dir: dir
    } do
      worktree = injected_worktree(dir)
      {:ok, files, secrets} = ContainerSpawn.worktree_files(worktree)
      request = Map.merge(request, %{worktree_files: files, worktree_secrets: secrets})

      assert {:ok, spec} =
               ContainerSpawn.remote_spec(request, %{argv: ["claude"], env: []}, "run-1")

      mount = Enum.find(spec["mounts"], &(&1["kind"] == "worktree"))

      assert Map.keys(mount["files"]) |> Enum.sort() == [
               ".claude/skills/tdd/SKILL.md",
               ".mcp.json"
             ]

      assert Base.decode64!(mount["files"][".mcp.json"]) == files[".mcp.json"]
      assert spec["secrets"]["ARBITER_MCP_TOKEN"] == "scope-token-xyz"
      refute inspect(spec["env"]) =~ "scope-token-xyz"
    end

    # AC2: every absolute path the primary hands the node must resolve on the
    # node side: under a mount the agent makes (worktree files declared or
    # tracked, home, config_dir, tmp), a published CLI, or a prompt file.
    test "every host path in the real argv resolves inside the container", %{
      request: request,
      tmp_dir: dir
    } do
      worktree = injected_worktree(dir)
      {:ok, files, secrets} = ContainerSpawn.worktree_files(worktree)

      request =
        Map.merge(request, %{
          worktree: worktree,
          home: Path.join(dir, "run/home"),
          config_dir: Path.join(dir, "run/claude-config"),
          tmp_dir: Path.join(dir, "run"),
          cli: [{String.duplicate("a", 64), "claude", ContainerSpawn.claude_path()}],
          worktree_files: files,
          worktree_secrets: secrets
        })

      argv = real_argv(Path.join(worktree, AgentConfig.Claude.filename()))
      env = [{"TMPDIR", request.tmp_dir}, {"CLAUDE_CONFIG_DIR", request.config_dir}]

      assert {:ok, spec} = ContainerSpawn.remote_spec(request, %{argv: argv, env: env}, "run-1")

      # Every argv element and env value that is itself an absolute path (free
      # text, such as the prompt or the inline settings JSON, is not a path).
      mounts = spec["mounts"] ++ spec["bridges"]
      worktree_mount = Enum.find(mounts, &(&1["kind"] == "worktree"))

      values =
        spec["command"] ++
          Map.values(spec["env"]) ++
          Map.values(Map.delete(spec["secrets"], "ARBITER_MCP_TOKEN"))

      paths = Enum.filter(values, &String.starts_with?(&1, "/"))

      assert Enum.any?(paths, &String.ends_with?(&1, "/.mcp.json")),
             "the argv should carry --mcp-config: #{inspect(spec["command"] |> Enum.take(-8))}"

      for path <- paths, path not in ["/dev/null"] do
        under =
          Enum.find(mounts, &(path == &1["path"] or String.starts_with?(path, &1["path"] <> "/")))

        assert under, "#{path} is under no mount of the spec"

        if under == worktree_mount do
          rel = Path.relative_to(path, worktree_mount["path"])

          assert Map.has_key?(worktree_mount["files"] || %{}, rel),
                 "#{path} is inside the worktree but is neither tracked nor shipped as a worktree file"
        end
      end
    end
  end
end

defmodule Arbiter.Worker.ContainerSpawnRegistryImageTest do
  @moduledoc """
  K8/A2: a node that advertises `caps.image = "registry"` is given the
  digest-pinned `ref` of a published image and no build plan; a build node, and
  an install with no `nodes.registry`, are untouched.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Image.Publisher

  @ref "registry.example.com/arbiter/worker@sha256:" <> String.duplicate("e", 64)
  @plan %{tag: "localhost/arbiter-dev/x:abc", plan: :a_plan_map}
  @ctx %{repo_path: "/repo", base: "main", seed_paths: nil}

  defp registry_node, do: %{id: "n1", caps: %{"image" => "registry"}}
  defp build_node, do: %{id: "n2", caps: %{"image" => "build"}}

  defp publish_opts(result) do
    server =
      start_supervised!(%{
        id: :pub,
        start: {Agent, :start_link, [fn -> result end]}
      })

    [publish: [stub: fn _ctx -> Agent.get(server, & &1) end]]
  end

  test "a build node keeps the plan and nothing is published" do
    assert {:ok, @plan} =
             ContainerSpawn.registry_image(@plan, build_node(), @ctx,
               publish: [stub: fn _ -> flunk("published") end]
             )
  end

  test "a registry node gets the ref and no plan" do
    opts = publish_opts({:ok, %{ref: @ref}})

    assert {:ok, %{tag: "localhost/arbiter-dev/x:abc", plan: nil, ref: @ref}} =
             ContainerSpawn.registry_image(@plan, registry_node(), @ctx, opts)
  end

  test "a registry node with nodes.registry unset is refused, not sent a plan it cannot build" do
    opts = publish_opts(:disabled)

    assert {:error, {:image_unavailable, :no_registry}} =
             ContainerSpawn.registry_image(@plan, registry_node(), @ctx, opts)
  end

  test "a timeout or push failure surfaces as image_unavailable" do
    opts = publish_opts({:error, {:timeout, 5}})

    assert {:error, {:image_unavailable, {:timeout, 5}}} =
             ContainerSpawn.registry_image(@plan, registry_node(), @ctx, opts)
  end

  test "Publisher is the default publisher" do
    assert Code.ensure_loaded?(Publisher)
  end
end
