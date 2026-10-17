defmodule Arbiter.Worker.VisualBaselines.ArchiveTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.VisualBaselines.Archive
  alias Arbiter.Worker.VisualBaselines.Config

  @moduletag :tmp_dir

  defp zip(files) do
    {:ok, {_name, bin}} =
      :zip.create(
        ~c"artifacts.zip",
        Enum.map(files, fn {n, b} -> {String.to_charlist(n), b} end),
        [:memory]
      )

    bin
  end

  defp config(overrides \\ %{}) do
    {:ok, c} =
      Config.validate(
        Map.merge(
          %{
            "job" => "visual",
            "artifact_path" => "test-results",
            "baseline_dir" => "e2e",
            "baseline_suffix" => "-chromium-linux.png"
          },
          overrides
        )
      )

    c
  end

  defp baseline(dir, rel, bytes) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  test "maps each actual image to its one existing baseline", %{tmp_dir: dir} do
    baseline(dir, "e2e/patient.spec.ts-snapshots/summary-chromium-linux.png", "old-a")
    baseline(dir, "e2e/charting.spec.ts-snapshots/chart-chromium-linux.png", "old-b")

    archive =
      zip([
        {"test-results/t1/summary-actual.png", "new-a"},
        {"test-results/t2/chart-actual.png", "new-b"},
        {"test-results/t2/chart-diff.png", "diff"},
        {"test-results/t2/trace.zip", "trace"},
        {"elsewhere/other-actual.png", "ignored"}
      ])

    assert {:ok, plan} = Archive.plan(archive, config(), dir)

    assert Enum.map(plan, &{&1.baseline, &1.bytes}) |> Enum.sort() == [
             {"e2e/charting.spec.ts-snapshots/chart-chromium-linux.png", "new-b"},
             {"e2e/patient.spec.ts-snapshots/summary-chromium-linux.png", "new-a"}
           ]
  end

  test "an actual identical to its baseline is not part of the plan", %{tmp_dir: dir} do
    baseline(dir, "e2e/a-chromium-linux.png", "same")
    baseline(dir, "e2e/b-chromium-linux.png", "old")

    archive = zip([{"test-results/a-actual.png", "same"}, {"test-results/b-actual.png", "new"}])

    assert {:ok, [%{baseline: "e2e/b-chromium-linux.png"}]} = Archive.plan(archive, config(), dir)
  end

  test "refuses what it cannot map exactly", %{tmp_dir: dir} do
    baseline(dir, "e2e/a-chromium-linux.png", "old")
    baseline(dir, "e2e/sub/dup-chromium-linux.png", "old")
    baseline(dir, "e2e/other/dup-chromium-linux.png", "old")

    assert {:error, :no_actuals} =
             Archive.plan(zip([{"test-results/readme.txt", "x"}]), config(), dir)

    assert {:error, {:no_baseline, "new-snapshot"}} =
             Archive.plan(zip([{"test-results/new-snapshot-actual.png", "x"}]), config(), dir)

    assert {:error, {:ambiguous_baseline, "dup"}} =
             Archive.plan(zip([{"test-results/dup-actual.png", "x"}]), config(), dir)

    assert {:error, {:duplicate_actual, "a"}} =
             Archive.plan(
               zip([{"test-results/x/a-actual.png", "1"}, {"test-results/y/a-actual.png", "2"}]),
               config(),
               dir
             )

    assert {:error, :no_change} =
             Archive.plan(zip([{"test-results/a-actual.png", "old"}]), config(), dir)

    assert {:error, {:too_many, 2, 1}} =
             Archive.plan(
               zip([{"test-results/a-actual.png", "1"}, {"test-results/dup-actual.png", "2"}]),
               config(%{"max_snapshots" => 1}),
               dir
             )

    assert {:error, :bad_archive} = Archive.plan("not a zip", config(), dir)
  end
end
