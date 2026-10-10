defmodule Arbiter.Nodes.LocalCapacityKindsTest do
  @moduledoc """
  RW8 guard tests (bd-3igo6h): the set of spawn kinds counted against the
  primary's cap is documented and pinned, every spawn site goes through the
  cap, and only a podman-backed Claude run on a private clone (the implementer,
  a ReviewGate reviewer or fix round, a `review: true` dispatch, a merge-queue fix or
  conflict pass; bd-7ays3v, bd-cgdhlu, bd-bg87oz) is ever
  a placement candidate.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Placement

  @lib Path.expand("../../../lib", __DIR__)
  @design Path.expand("../../../../../docs/design/remote-workers.md", __DIR__)

  # The one place the list is spelled out in a test: change a kind and this
  # fails, which is the point.
  @pinned_kinds ~w(conflict_pass fix_pass implementer redispatch resume review review_fix_round reviewer)a

  describe "the spawn kinds counted against the primary's cap" do
    test "are exactly the pinned set" do
      assert LocalCapacity.kinds() |> Map.keys() |> Enum.sort() == @pinned_kinds
    end

    test "Placement knows the same kinds" do
      assert Enum.sort(Placement.kinds()) == @pinned_kinds
    end

    test "every kind is capped one of two documented ways" do
      assert LocalCapacity.kinds() |> Map.values() |> Enum.uniq() |> Enum.sort() ==
               [:at_cap, :zero_only]

      assert LocalCapacity.kinds()[:implementer] == :at_cap
      assert LocalCapacity.kinds()[:redispatch] == :at_cap
      assert LocalCapacity.kinds()[:resume] == :at_cap
    end

    test "the design doc lists every kind in its RW8 section" do
      doc = File.read!(@design)
      [_, section] = String.split(doc, "**[RW8, bd-3igo6h] As built.**", parts: 2)

      for kind <- @pinned_kinds do
        assert section =~ "`#{kind}`", "docs/design/remote-workers.md RW8 section omits `#{kind}`"
      end
    end
  end

  describe "every spawn site goes through the cap" do
    # Files that start a worker, and the module that applies the cap for them.
    @gates %{
      "worker/dispatch.ex" => "LocalCapacity",
      "worker/review_gate.ex" => "LocalCapacity",
      "workflows/merge_queue/fix_pass_dispatcher.ex" => "PassAdmission",
      "workflows/merge_queue/conflict_resolver.ex" => "PassAdmission"
    }

    test "a new `Worker.start`/`start_or_reap_terminal` call site must be added here" do
      sites =
        @lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          src = File.read!(path)
          src =~ ~r/\bWorker\.start\(|\bWorker\.start_or_reap_terminal\(/
        end)
        |> Enum.map(&Path.relative_to(&1, Path.join(@lib, "arbiter")))
        |> Enum.sort()

      assert sites == @gates |> Map.keys() |> Enum.sort(),
             "a file that starts a worker is not in the LocalCapacity gate list; route it " <>
               "through Arbiter.Nodes.LocalCapacity (or PassAdmission) and add it here"
    end

    test "each site references its gate, and PassAdmission applies LocalCapacity" do
      for {file, gate} <- @gates do
        src = File.read!(Path.join([@lib, "arbiter", file]))
        assert src =~ gate, "#{file} must go through #{gate}"
      end

      pass_admission =
        File.read!(Path.join(@lib, "arbiter/workflows/merge_queue/pass_admission.ex"))

      assert pass_admission =~ "LocalCapacity.admit("
    end

    test "nothing under sessions/ (coordinator PTYs) references Arbiter.Nodes" do
      offenders =
        @lib
        |> Path.join("arbiter/sessions/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ ~r/Arbiter\.Nodes|Executor/))

      assert offenders == []
    end
  end

  describe "only podman-backed Claude runs on a private clone are ever placement candidates" do
    test "across every kind, provider, layout and mode, only those kinds are eligible" do
      kinds = Placement.kinds()
      providers = [:claude, :codex, :agy, :gemini, :grok, nil]
      layouts = [:private_clone, :worktree, :shared, nil]

      eligible =
        for kind <- kinds,
            provider <- providers,
            layout <- layouts,
            no_pr? <- [false, true],
            mode <- Placement.modes(),
            Placement.eligible(%{
              task_id: "t",
              kind: kind,
              provider: provider,
              layout: layout,
              no_pr?: no_pr?,
              mode: mode
            }) == :ok do
          {kind, provider, layout, no_pr?, mode}
        end

      # Exactly the Claude runs that have a container backend and a private clone
      # (bd-7ays3v; the `review: true` dispatch and the reviewer, bd-cgdhlu), in
      # the two modes that allow a node.
      assert Enum.sort(eligible) ==
               for(
                 kind <-
                   [
                     :conflict_pass,
                     :fix_pass,
                     :implementer,
                     :review,
                     :review_fix_round,
                     :reviewer
                   ],
                 mode <- [:prefer_remote, :remote_only],
                 do: {kind, :claude, :private_clone, false, mode}
               )
    end
  end
end
