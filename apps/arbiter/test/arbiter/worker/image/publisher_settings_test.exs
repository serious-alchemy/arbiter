defmodule Arbiter.Worker.Image.PublisherSettingsTest do
  @moduledoc """
  K8 production path: the config comes from the persisted (Cloak-encrypted)
  settings and the supervised, named `Publisher` and `Builder` are used, as in
  dispatch. Only podman is replaced.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Settings.Registry, as: Settings
  alias Arbiter.Worker.Image.Publisher

  @moduletag :tmp_dir

  @password "settings-path-NEVER-LOGGED"

  test "nothing is published while nodes.registry is unset", %{tmp_dir: tmp} do
    ctx = %{plan: plan(), repo_path: nil, base: "main", seed_paths: []}
    assert Publisher.ensure_ready(ctx, runner: runner(self()), scratch: tmp) == :disabled
    refute_received {:podman, _}
  end

  test "with settings configured, the supervised publisher pushes and pins a digest",
       %{tmp_dir: tmp} do
    {:ok, _} = Settings.put("nodes.registry", "registry.example.com/arb")
    {:ok, _} = Settings.put("nodes.registry_username", "bot")
    {:ok, _} = Settings.put("nodes.registry_password", @password)

    ctx = %{plan: plan(), repo_path: nil, base: "main", seed_paths: []}
    cli = [{write(tmp, "claude"), "/opt/arbiter/cli/claude"}]

    assert {:ok, %{ref: ref}} =
             Publisher.ensure_ready(ctx,
               runner: runner(self()),
               scratch: tmp,
               cli: cli,
               timeout_ms: 10_000
             )

    assert ref =~ ~r|\Aregistry\.example\.com/arb/worker@sha256:[0-9a-f]{64}\z|

    status = Publisher.status(probe: fn _ -> :ok end)
    assert status.configured and status.password_set and status.reachable
    refute inspect(status) =~ @password

    for {:podman, args} <- drain(), do: refute(Enum.any?(args, &(&1 =~ @password)))
  end

  defp plan do
    n = System.unique_integer([:positive])

    %{
      tag: "localhost/arbiter-dev/generated-s#{n}:aaaaaaaaaaaa",
      name: "generated-s#{n}",
      hash: "aaaaaaaaaaaa",
      containerfile: "FROM scratch",
      build_args: [],
      base: %{
        tag: "localhost/arbiter-dev/base:bbbbbbbbbbbb",
        name: "base",
        hash: "b",
        containerfile: "FROM scratch"
      }
    }
  end

  defp write(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, name)
    path
  end

  defp runner(test) do
    fn "podman", args, _opts ->
      send(test, {:podman, args})

      if hd(args) == "push" do
        i = Enum.find_index(args, &(&1 == "--digestfile"))
        File.write!(Enum.at(args, i + 1), "sha256:" <> String.duplicate("f", 64))
      end

      {"", 0}
    end
  end

  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
