defmodule Arbiter.Worker.Image.RegistryReportTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.RegistryReport

  defp workspace(config), do: %{id: "ws-1", name: "ws", config: config}

  defp build(workspaces, config) do
    RegistryReport.build(
      workspaces: workspaces,
      config: config,
      probe: fn _ -> :ok end,
      anonymous_probe: fn _, _ -> :private end
    )
  end

  @install %{
    registry: "registry.example.com/arb",
    username: "bot",
    password: "push-secret",
    insecure?: false
  }

  test "SI4a: the install registry reports its pull credential (install-wide pair)" do
    with_pull = Map.merge(@install, %{pull_username: "ro", pull_password: "ro-secret"})

    assert [%{origin: "install", pull_credential: "install"} = entry] = build([], with_pull)
    refute inspect(entry) =~ "ro-secret"
    assert [%{pull_credential: "none"}] = build([], @install)
  end

  test "SI4a: a registry with a repo-level pull_credentials_ref reports ref; public_ok reports anonymous" do
    ws =
      workspace(%{
        "repo_paths" => %{"vstim" => "/r/vstim", "pub" => "/r/pub"},
        "worker" => %{
          "repos" => %{
            "vstim" => %{
              "image" => %{
                "registry" => "ghcr.io/ryan",
                "pull_credentials_ref" => "secret:READ"
              }
            },
            "pub" => %{"image" => %{"registry" => "docker.io/pub", "public_ok" => true}}
          }
        }
      })

    entries = build([ws], @install)
    by_registry = Map.new(entries, &{&1.registry, &1})

    assert by_registry["ghcr.io/ryan"].pull_credential == "ref"
    assert by_registry["docker.io/pub"].pull_credential == "anonymous"
  end
end
