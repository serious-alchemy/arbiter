# Script for populating the database. Run via:
#
#     mix run apps/arbiter/priv/repo/seeds.exs
#
# (or automatically as part of `mix ecto.setup` via the aliases in mix.exs)
#
# Idempotent — re-running won't duplicate.

require Ash.Query

alias Arbiter.Tasks.Workspace

default_name = "default"

existing =
  Workspace
  |> Ash.Query.filter(name == ^default_name)
  |> Ash.read_one!()

case existing do
  nil ->
    {:ok, _ws} =
      Ash.create(Workspace, %{
        name: default_name,
        description: "Default workspace shipped at boot. No external tracker.",
        config: %{
          "tracker" => %{"type" => "none"},
          "agent" => %{
            "config" => %{
              "codex" => %{
                "tier_models" => %{
                  "economy" => "gpt-5.6-luna",
                  "standard" => "gpt-5.6-terra",
                  "premium" => "gpt-5.6-terra",
                  "flagship" => "gpt-5.6-terra"
                }
              }
            }
          }
        }
      })

    IO.puts("✓ Seeded default workspace")

  %Workspace{config: config} = ws ->
    # Idempotent update: if the workspace exists but lacks Codex tier model
    # overrides, add them. This allows existing installs to benefit from the
    # plan-aware defaults without manually updating each workspace.
    case get_in(config || %{}, ["agent", "config", "codex", "tier_models"]) do
      nil ->
        updated_config =
          config
          |> update_in(["agent", "config"], &(&1 || %{}))
          |> update_in(["agent", "config", "codex"], &(&1 || %{}))
          |> put_in(
            ["agent", "config", "codex", "tier_models"],
            %{
              "economy" => "gpt-5.6-luna",
              "standard" => "gpt-5.6-terra",
              "premium" => "gpt-5.6-terra",
              "flagship" => "gpt-5.6-terra"
            }
          )

        {:ok, _} = Ash.update(ws, %{config: updated_config})
        IO.puts("✓ Updated default workspace with Codex tier models")

      %{} ->
        IO.puts("• Default workspace already has Codex tier models; skipping")
    end
end

Arbiter.Skills.Seeds.seed!()
IO.puts("✓ Seeded built-in skills")
