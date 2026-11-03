defmodule Arbiter.Worker.Image.PublishLedgerTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.Image.PublishLedger

  @moduletag :tmp_dir

  test "images/1 lists each repo's newest publish with its CLI set, providers and seed", %{
    tmp_dir: tmp
  } do
    opts = [ledger: Path.join(tmp, "ledger.term")]

    facts = %{
      providers: ["claude"],
      clis: [%{name: "claude", version: "2.1.0"}],
      seed: %{status: :pushed, reason: nil}
    }

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [ref: "r@sha256:old", now: ~U[2026-01-01 00:00:00Z]] ++ opts
    )

    PublishLedger.record(
      %{repo: "a", repo_path: "/a"},
      [ref: "r@sha256:new", image: facts, now: ~U[2026-01-02 00:00:00Z]] ++ opts
    )

    assert [%{repo: "a", ref: "r@sha256:new", providers: ["claude"], seed: %{status: :pushed}}] =
             PublishLedger.images(opts)

    assert PublishLedger.images(ledger: nil) == []
  end
end
