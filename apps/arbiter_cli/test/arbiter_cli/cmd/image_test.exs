defmodule ArbiterCli.Cmd.ImageTest do
  @moduledoc "`arb image list|build|refresh|prune` (bd-9r5jdt)."
  use ArbiterCli.CliCase, async: false

  @base "localhost/arbiter-dev/base:aaaaaaaaaaaa"
  @tool "localhost/arbiter-dev/beam-1.19.4-28.2:bbbbbbbbbbbb"

  @listing %{
    "podman" => true,
    "images" => [
      %{
        "tag" => @tool,
        "name" => "beam-1.19.4-28.2",
        "hash" => "bbbbbbbbbbbb",
        "kind" => "toolchain",
        "created" => 1_790_000_000,
        "size" => 800_000_000
      },
      %{
        "tag" => @base,
        "name" => "base",
        "hash" => "aaaaaaaaaaaa",
        "kind" => "base",
        "created" => 1_789_990_000,
        "size" => 250_000_000
      }
    ],
    "pins" => [
      %{
        "ref" => "docker.io/library/debian:trixie-slim",
        "digest" => "sha256:" <> String.duplicate("a", 64),
        "resolved_at" => "2026-10-03T00:00:00Z"
      }
    ],
    "refreshed_at" => nil,
    "refresh_due" => false
  }

  describe "arb image list" do
    test "prints the images and the digest pins" do
      stub_get("/api/images", @listing)
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["list"]) end)

      assert code == 0
      assert out =~ "beam-1.19.4-28.2"
      assert out =~ "bbbbbbbbbbbb"
      assert out =~ "base"
      assert out =~ "docker.io/library/debian:trixie-slim"
      assert out =~ "sha256:" <> String.duplicate("a", 64)
    end

    test "says so when there are no images" do
      stub_get("/api/images", %{@listing | "images" => [], "pins" => []})
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["list"]) end)
      assert code == 0
      assert out =~ "No worker images"
    end

    test "notes a missing podman" do
      stub_get("/api/images", %{@listing | "podman" => false, "images" => []})
      {out, _err, _code} = capture(fn -> ArbiterCli.Cmd.Image.run(["list"]) end)
      assert out =~ "podman is not installed"
    end

    test "--json prints the response body" do
      stub_get("/api/images", @listing)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Image.run(["list", "--json"]) end)
      assert Jason.decode!(out) == @listing
    end
  end

  describe "arb image build" do
    @built %{
      "tag" => @tool,
      "built" => [@base, @tool],
      "cached" => false,
      "name" => "beam-1.19.4-28.2",
      "base_tag" => @base,
      "source" => "generated",
      "ref" => "refs/remotes/origin/main",
      "default_branch" => "main",
      "toolchain" => %{"erlang" => "28.2", "elixir" => "1.19.4", "node" => nil}
    }

    test "posts the repo and reports what was built and from where" do
      stub_post("/api/images/build", @built, 200)
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["build", "arbiter"]) end)

      assert code == 0
      assert out =~ @tool
      assert out =~ "built 2 layer(s)"
      assert out =~ "refs/remotes/origin/main"
    end

    test "reports a cached image" do
      stub_post("/api/images/build", %{@built | "built" => [], "cached" => true}, 200)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Image.run(["build", "arbiter"]) end)
      assert out =~ "already built"
    end

    test "requires a repo" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["build"]) end)
      assert code != 0
      assert err =~ "repo"
    end

    test "surfaces a server error" do
      stub_post(
        "/api/images/build",
        %{"error" => %{"message" => "image build failed: step 2 failed"}},
        409
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["build", "arbiter"]) end)
      assert code != 0
      assert err =~ "step 2 failed"
    end

    test "--json prints the response body" do
      stub_post("/api/images/build", @built, 200)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Image.run(["build", "arbiter", "--json"]) end)
      assert Jason.decode!(out) == @built
    end
  end

  describe "arb image refresh / prune" do
    test "refresh reports moved bases and pruned tags" do
      stub_post(
        "/api/images/refresh",
        %{
          "changed" => [
            %{
              "ref" => "docker.io/library/debian:trixie-slim",
              "from" => "sha256:a",
              "to" => "sha256:b"
            }
          ],
          "failed" => [],
          "pruned" => %{"removed" => [@base], "failed" => []}
        },
        200
      )

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Image.run(["refresh"]) end)
      assert out =~ "docker.io/library/debian:trixie-slim"
      assert out =~ "sha256:b"
      assert out =~ @base
    end

    test "prune reports what it removed" do
      stub_post("/api/images/prune", %{"removed" => [@base], "failed" => []}, 200)
      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Image.run(["prune"]) end)
      assert out =~ "Removed 1"
      assert out =~ @base
    end
  end

  test "an unknown subcommand is a usage error" do
    {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Image.run(["frobnicate"]) end)
    assert code == 2
    assert err =~ "unknown image subcommand"
  end
end
