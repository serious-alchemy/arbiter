defmodule Arbiter.Guardrails.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Config

  @valid %{
    "bindings" => %{
      "prod_read" => %{
        "grant_by" => "coordinator",
        "min_tier" => "privileged",
        "enforced_read_only" => true,
        "tunnels" => ["replica.internal:5432"],
        "env_from_secret" => %{"RO_DATABASE_URL" => "prod_ro_url"}
      },
      "secrets:broker_demo" => %{"env_from_secret" => %{"BROKER_KEY" => "broker_demo_key"}},
      "tracker_write" => %{"token_secret" => "github_worker_token"}
    },
    "defaults" => %{"permissions" => []},
    "repos" => %{
      "tonic" => %{
        "defaults" => %{"permissions" => ["phi_data"]},
        "subjects" => [%{"match" => %{"provider" => "antigravity"}, "max_difficulty" => 1}]
      }
    },
    "subjects" => [
      %{
        "match" => %{"provider" => "antigravity", "model" => "gemini-*-flash-*"},
        "max_tier" => "probation",
        "min_mode" => "strict",
        "egress" => "none",
        "max_difficulty" => "D2",
        "spend" => %{"action" => "park", "tokens" => 1_000_000, "wall_clock_s" => 1800},
        "review" => %{"cross_family" => "required", "same_family_fallback" => "hold"}
      }
    ]
  }

  test "the design's example block is valid" do
    assert Config.validate(@valid) == []
  end

  test "nil is valid (no block)" do
    assert Config.validate(nil) == []
  end

  test "a non-map block is refused" do
    assert [_] = Config.validate("strict")
  end

  test "unknown keys are refused at every level" do
    assert [msg] = Config.validate(%{"bogus" => 1})
    assert msg =~ "unknown key"

    assert [msg] = Config.validate(%{"repos" => %{"r" => %{"nope" => 1}}})
    assert msg =~ "guardrails.repos.r has unknown key"

    assert Enum.any?(
             Config.validate(%{
               "subjects" => [%{"match" => %{"provider" => "x"}, "tier" => "trusted"}]
             }),
             &(&1 =~ "unknown key")
           )
  end

  test "enum fields are checked" do
    errors =
      Config.validate(%{
        "subjects" => [
          %{
            "match" => %{"provider" => "x"},
            "max_tier" => "godmode",
            "min_mode" => "yolo",
            "egress" => "wide",
            "max_difficulty" => 9
          }
        ],
        "bindings" => %{"prod_read" => %{"grant_by" => "anyone", "min_tier" => "x"}}
      })

    for field <- ~w(max_tier min_mode egress max_difficulty grant_by min_tier) do
      assert Enum.any?(errors, &(&1 =~ field)),
             "expected an error naming #{field}: #{inspect(errors)}"
    end
  end

  test "a cap must name a match" do
    assert Enum.any?(
             Config.validate(%{"subjects" => [%{"max_tier" => "probation"}]}),
             &(&1 =~ "match")
           )

    assert Enum.any?(Config.validate(%{"subjects" => [%{"match" => %{}}]}), &(&1 =~ "match"))
  end

  test "binding names, hosts and secret maps are checked" do
    errors =
      Config.validate(%{
        "bindings" => %{
          "Not Valid" => %{},
          "prod_ssh" => %{"hosts" => ["not a host"], "env_from_secret" => %{"X" => ""}}
        },
        "defaults" => %{"permissions" => ["ok_perm", "bad perm"]}
      })

    assert Enum.any?(errors, &(&1 =~ "Not Valid"))
    assert Enum.any?(errors, &(&1 =~ "hosts"))
    assert Enum.any?(errors, &(&1 =~ "env_from_secret"))
    assert Enum.any?(errors, &(&1 =~ "bad perm"))
  end

  test "parse_caps drops what does not parse, keeps what does" do
    assert Config.parse_caps(%{
             "max_tier" => "probation",
             "egress" => "bogus",
             "max_difficulty" => "D3"
           }) ==
             %{max_tier: :probation, max_difficulty: 3}
  end

  test "block/1 reads string or atom keyed configs and structs' config" do
    assert Config.block(%{config: %{"guardrails" => %{"subjects" => []}}}) == %{"subjects" => []}
    assert Config.block(%{"guardrails" => %{subjects: []}}) == %{"subjects" => []}
    assert Config.block(nil) == %{}
    assert Config.block(%{config: %{}}) == %{}
  end
end
