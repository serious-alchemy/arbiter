defmodule Arbiter.SeedsTest do
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureIO

  require Ash.Query

  alias Arbiter.Agents.Codex
  alias Arbiter.Tasks.Workspace

  @seeds Path.expand("../../priv/repo/seeds.exs", __DIR__)

  setup do
    on_exit(&Codex.Config.clear/0)
  end

  test "the default workspace's Codex tier map reaches the Codex config" do
    capture_io(fn -> Code.eval_file(@seeds) end)

    ws = Workspace |> Ash.Query.filter(name == "default") |> Ash.read_one!()
    Codex.Config.put_active(ws)
    {:ok, cfg} = Codex.Config.resolve()

    assert cfg.raw["tier_models"] == %{
             "economy" => "gpt-5.6-luna",
             "standard" => "gpt-5.6-terra",
             "premium" => "gpt-5.6-terra",
             "flagship" => "gpt-5.6-terra"
           }
  end

  test "re-running leaves an existing default workspace alone" do
    capture_io(fn -> Code.eval_file(@seeds) end)
    assert capture_io(fn -> Code.eval_file(@seeds) end) =~ "already exists"
    assert [_] = Workspace |> Ash.Query.filter(name == "default") |> Ash.read!()
  end
end
