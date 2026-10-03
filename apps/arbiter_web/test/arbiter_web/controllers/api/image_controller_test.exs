defmodule ArbiterWeb.Api.ImageControllerTest do
  @moduledoc """
  The transport behind `arb image list|build|refresh|prune` (bd-9r5jdt). Every
  podman/skopeo call goes through the `:worker_image_runner` app env, so no
  container runtime is needed.
  """
  use ArbiterWeb.ConnCase, async: false

  @digest "sha256:" <> String.duplicate("d", 64)

  setup do
    scratch = tmp_dir()
    {:ok, built} = Agent.start_link(fn -> %{tags: MapSet.new(), files: []} end)

    runner = fn
      "skopeo", ["inspect" | _], _ ->
        {@digest <> "\n", 0}

      "podman", ["image", "exists", tag], _ ->
        if Agent.get(built, &MapSet.member?(&1.tags, tag)), do: {"", 0}, else: {"", 1}

      "podman", ["build" | rest], _ ->
        file =
          rest
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.find_value(fn [f, v] -> f == "--file" && v end)

        tag =
          rest
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.find_value(fn [f, v] -> f == "--tag" && v end)

        if Agent.get(built, &Map.get(&1, :fail, false)) do
          {"step 2 failed", 1}
        else
          Agent.update(built, fn s ->
            %{s | tags: MapSet.put(s.tags, tag), files: [File.read!(file) | s.files]}
          end)

          {"ok", 0}
        end

      "podman", ["images" | _], _ ->
        {Jason.encode!(
           for tag <- Agent.get(built, &MapSet.to_list(&1.tags)) do
             %{
               "Id" => "id",
               "Names" => [tag],
               "Created" => 5,
               "Size" => 9,
               "Labels" => %{"arbiter.dev-image" => "1"}
             }
           end
         ), 0}

      "podman", ["rmi", _], _ ->
        {"", 0}
    end

    prior =
      for k <- [:worker_image_runner, :image_root, :repo_paths],
          do: {k, Application.get_env(:arbiter, k)}

    Application.put_env(:arbiter, :worker_image_runner, runner)
    Application.put_env(:arbiter, :image_root, scratch)
    # The scratch root build directories land in.
    prior_scratch = Application.get_env(:arbiter, :scratch_root)
    Application.put_env(:arbiter, :scratch_root, scratch)

    on_exit(fn ->
      for {k, v} <- prior do
        if v == nil,
          do: Application.delete_env(:arbiter, k),
          else: Application.put_env(:arbiter, k, v)
      end

      if prior_scratch == nil,
        do: Application.delete_env(:arbiter, :scratch_root),
        else: Application.put_env(:arbiter, :scratch_root, prior_scratch)
    end)

    {:ok, built: built}
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "imgctl-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
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

  defp register_repo(name, containerfile) do
    dir = tmp_dir()
    git!(dir, ["init", "-q", "-b", "main"])
    File.mkdir_p!(Path.join(dir, ".arbiter"))
    File.write!(Path.join(dir, ".arbiter/Containerfile"), containerfile)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "init"])
    Application.put_env(:arbiter, :repo_paths, %{name => dir})
    dir
  end

  test "POST /api/images/build builds the default branch's Containerfile, not the worker branch's",
       %{
         conn: conn,
         built: built
       } do
    dir = register_repo("imgrepo", "FROM ${ARBITER_BASE}\nRUN echo default-branch\n")
    git!(dir, ["checkout", "-q", "-b", "worker/evil"])
    File.write!(Path.join(dir, ".arbiter/Containerfile"), "FROM ${ARBITER_BASE}\nRUN echo evil\n")
    git!(dir, ["commit", "-q", "-am", "evil"])

    resp = conn |> post("/api/images/build", %{"repo" => "imgrepo"}) |> json_response(200)

    assert resp["tag"] =~ ~r|^localhost/arbiter-dev/repo-imgrepo:[0-9a-f]{12}$|
    assert resp["cached"] == false
    assert length(resp["built"]) == 2
    assert resp["source"] == "repo"
    assert resp["default_branch"] == "main"
    assert resp["ref"] == "refs/heads/main"

    texts = Agent.get(built, & &1.files) |> Enum.join("\n")
    assert texts =~ "echo default-branch"
    refute texts =~ "echo evil"
  end

  test "a second build request for the same tag is cached", %{conn: conn} do
    register_repo("imgrepo2", "FROM ${ARBITER_BASE}\nRUN echo x\n")
    first = conn |> post("/api/images/build", %{"repo" => "imgrepo2"}) |> json_response(200)

    again =
      recycle(conn) |> post("/api/images/build", %{"repo" => "imgrepo2"}) |> json_response(200)

    assert again["tag"] == first["tag"]
    assert again["cached"] == true
    assert again["built"] == []
  end

  test "an unregistered repo is a 400", %{conn: conn} do
    Application.put_env(:arbiter, :repo_paths, %{})
    resp = conn |> post("/api/images/build", %{"repo" => "nope"}) |> json_response(400)
    assert resp["error"]["message"] =~ "not registered"
  end

  test "a missing repo param is a 400", %{conn: conn} do
    assert conn |> post("/api/images/build", %{}) |> json_response(400)
  end

  test "a failed build is a 409 carrying the build output", %{conn: conn, built: built} do
    register_repo("imgrepo3", "FROM ${ARBITER_BASE}\n")
    Agent.update(built, &Map.put(&1, :fail, true))

    resp = conn |> post("/api/images/build", %{"repo" => "imgrepo3"}) |> json_response(409)
    assert resp["error"]["message"] =~ "step 2 failed"
  end

  test "GET /api/images lists images and the digest pins", %{conn: conn} do
    register_repo("imgrepo4", "FROM ${ARBITER_BASE}\n")
    recycle(conn) |> post("/api/images/build", %{"repo" => "imgrepo4"}) |> json_response(200)

    resp = conn |> get("/api/images") |> json_response(200)

    assert Enum.any?(resp["images"], &(&1["kind"] == "base"))
    assert Enum.any?(resp["images"], &(&1["name"] == "repo-imgrepo4"))

    assert [%{"ref" => "docker.io/library/debian:bookworm-slim", "digest" => @digest}] =
             resp["pins"]

    assert resp["refresh_due"] == false
  end

  test "POST /api/images/refresh re-resolves the pins and prunes", %{conn: conn} do
    register_repo("imgrepo5", "FROM ${ARBITER_BASE}\n")
    recycle(conn) |> post("/api/images/build", %{"repo" => "imgrepo5"}) |> json_response(200)

    resp = conn |> post("/api/images/refresh", %{}) |> json_response(200)
    assert resp["changed"] == []
    assert resp["failed"] == []
    assert %{"removed" => [], "failed" => []} = resp["pruned"]
  end

  test "POST /api/images/prune reports what it removed", %{conn: conn} do
    resp = conn |> post("/api/images/prune", %{}) |> json_response(200)
    assert resp["removed"] == []
  end
end
