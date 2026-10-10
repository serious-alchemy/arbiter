defmodule Arbiter.NodeAgent.PodChannel.BootBundleTest do
  @moduledoc """
  What `/boot` hands the pod's `seed` container (`docs/design/remote-workers.md`
  §16 K§10.1, K§12): one tar, built in memory (a secret never touches the
  controller's disk), with the run's certificates and the per-run secrets and
  seed files, and nothing the primary did not put in the run's spec.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.PodChannel.{BootBundle, Cert}
  alias Arbiter.NodeAgent.RunSpec

  defp spec!(overrides \\ %{}) do
    {:ok, spec} =
      RunSpec.validate(
        Map.merge(
          %{
            "version" => 1,
            "run" => "run-1",
            "task" => "bd-abc",
            "name" => "arb-bd-abc-1234",
            "image" => %{"tag" => "localhost/arbiter-dev/beam:abc123", "plan" => nil},
            "cwd" => "/work/tree",
            "mounts" => [
              %{
                "kind" => "worktree",
                "path" => "/work/tree",
                "files" => %{".mcp.json" => Base.encode64(~s({"bearer":"w-tier"}))}
              },
              %{
                "kind" => "config_dir",
                "path" => "/work/config",
                "files" => %{"CLAUDE.md" => Base.encode64("# memory")}
              },
              %{
                "kind" => "prompt",
                "path" => "/work/prompt.md",
                "content" => Base.encode64("do the thing")
              }
            ],
            "bridges" => [
              %{"name" => "proxy", "path" => "/var/eg/proxy.sock"},
              %{"name" => "arb", "path" => "/var/eg/arb.sock"}
            ],
            "secrets" => %{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-it's-secret"},
            "checkout" => %{"branch" => "feature/x", "base" => "main", "interval_s" => 60},
            "command" => ["claude", "--print"]
          },
          overrides
        )
      )

    spec
  end

  defp leaves do
    now = DateTime.utc_now()
    ca = Cert.ca(DateTime.add(now, -60), DateTime.add(now, 3600))

    for name <- ~w(proxy arb control), into: %{} do
      {name, Cert.leaf(ca, "run-1", name, DateTime.add(now, -60), DateTime.add(now, 600))}
    end
  end

  defp unpack(tar) do
    {:ok, files} = :erl_tar.extract({:binary, tar}, [:memory])
    Map.new(files, fn {name, body} -> {to_string(name), body} end)
  end

  test "the tar carries a certificate and key per bridge plus the control leaf" do
    leaves = leaves()
    files = unpack(BootBundle.build(spec!(), leaves))

    for name <- ~w(proxy arb control) do
      assert files["tls/#{name}.crt"] == Cert.pem_cert(leaves[name].der)
      assert files["tls/#{name}.key"] == Cert.pem_key(leaves[name].key)
    end
  end

  test "secrets are rendered exactly as the agent's secrets file" do
    files = unpack(BootBundle.build(spec!(), leaves()))

    assert files["secrets.env"] ==
             Arbiter.NodeAgent.Secrets.render(%{"CLAUDE_CODE_OAUTH_TOKEN" => "sk-it's-secret"})
  end

  test "no secrets file when the run has none" do
    files = unpack(BootBundle.build(spec!(%{"secrets" => %{}}), leaves()))

    refute Map.has_key?(files, "secrets.env")
  end

  test "seed files land under their mount kind, and the manifest says where they go" do
    files = unpack(BootBundle.build(spec!(), leaves()))

    assert files["worktree/.mcp.json"] == ~s({"bearer":"w-tier"})
    assert files["config_dir/CLAUDE.md"] == "# memory"
    assert files["prompt/0"] == "do the thing"

    manifest = Jason.decode!(files["manifest.json"])
    assert manifest["run"] == "run-1"
    assert manifest["prompts"] == [%{"file" => "prompt/0", "path" => "/work/prompt.md"}]

    assert manifest["checkout"] == %{
             "branch" => "feature/x",
             "base" => "main",
             "interval_s" => 60
           }

    assert Enum.sort(manifest["bridges"]) == ["arb", "proxy"]
  end

  test "the manifest holds no secret" do
    files = unpack(BootBundle.build(spec!(), leaves()))

    refute files["manifest.json"] =~ "sk-it"
    refute files["manifest.json"] =~ "w-tier"
  end

  describe "Tar.encode/1" do
    alias Arbiter.NodeAgent.PodChannel.BootBundle.Tar

    test "round-trips files of any size, including empty and block-aligned ones" do
      entries = [
        {"empty", "", 0o644},
        {"aligned", String.duplicate("a", 512), 0o600},
        {"big", :crypto.strong_rand_bytes(100_000), 0o600},
        {"dir/nested/file", "x", 0o644}
      ]

      tar = Tar.encode(entries)
      assert rem(byte_size(tar), 512) == 0
      back = unpack(tar)

      for {name, body, _} <- entries, do: assert(back[name] == body)
    end

    test "records the mode, so keys are 0600" do
      tar = Tar.encode([{"k", "secret", 0o600}])
      <<_name::binary-size(100), mode::binary-size(8), _::binary>> = tar

      assert mode == "0000600\0"
    end

    test "refuses a name the format cannot carry or that escapes the extraction root" do
      for bad <- ["/etc/passwd", "../x", "a/../../x", String.duplicate("a", 101), ""] do
        assert_raise ArgumentError, fn -> Tar.encode([{bad, "x", 0o644}]) end
      end
    end
  end
end
