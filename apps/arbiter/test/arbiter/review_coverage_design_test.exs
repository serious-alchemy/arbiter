defmodule Arbiter.ReviewCoverageDesignTest do
  @moduledoc """
  Keeps the review-coverage design doc's guard inventory honest (bd-6woz0x).

  The doc's whole value is an inventory of every guard in the review/merge
  control plane. Each guard is cited by code identity, never by line number —
  line numbers rot on every unrelated edit above the function and cause merge
  conflicts between PRs touching different gates:

      `Arbiter.Worker.Watchdog.clear_reviewed_latch`
      `Arbiter.Worker.Watchdog.clear_reviewed_latch/2`

  a backticked `Module.name` (optionally `/arity`) whose module starts with
  `Arbiter.`. This test finds the module's source file by its `defmodule` and
  asserts that `name` is still defined there (a function, macro or `@attribute`) or,
  for non-function symbols such as struct fields and atoms, still appears as an
  identifier. With `/arity`, a `def`/`defp` of that arity must exist. The position in the file is
  irrelevant. Prose may name anything else however it likes.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @doc_path Path.join(@repo_root, "docs/review-coverage-and-guard-policy.md")

  # `Arbiter.Some.Module.name` or `...name/arity`, in backticks.
  @citation ~r/`(Arbiter(?:\.[A-Z][A-Za-z0-9]*)+)\.([a-z_][A-Za-z0-9_]*[?!]?)(?:\/(\d+))?`/

  setup_all do
    assert File.exists?(@doc_path),
           "expected the review-coverage design doc at docs/review-coverage-and-guard-policy.md"

    {:ok, doc: File.read!(@doc_path)}
  end

  test "the doc cites the control-plane files the inventory must cover", %{doc: doc} do
    for module <- ~w(
          Arbiter.Worker.ReviewGate
          Arbiter.Worker.Watchdog
          Arbiter.Workflows.MergeQueue
          Arbiter.Workflows.ReviewPatrol
          Arbiter.Workflows.PRPatrol
          Arbiter.Mergers.ReviewedSha
        ) do
      assert doc =~ "`#{module}.",
             "the guard inventory does not cite #{module} — AC2 requires every guard/refusal " <>
               "path in the review/merge control plane"
    end
  end

  test "the doc carries no file:line citations", %{doc: doc} do
    assert Regex.scan(~r/`apps\/[^`\s:]+\.exs?:\d+`/, doc) == [],
           "cite code as `Module.function/arity`, not `path:line` — line numbers rot"
  end

  test "every Module.function citation still resolves", %{doc: doc} do
    citations = Regex.scan(@citation, doc)

    assert length(citations) >= 25,
           "expected at least 25 `Module.function` citations, found #{length(citations)}"

    index = module_index()

    stale =
      for [_, module, name | rest] <- citations,
          problem = citation_problem(index, module, name, rest),
          do: "#{module}.#{name} — #{problem}"

    assert stale == [],
           "stale citations in docs/review-coverage-and-guard-policy.md; re-anchor them " <>
             "against the current source:\n  " <> Enum.join(Enum.uniq(stale), "\n  ")
  end

  describe "citation_problem/4" do
    @source """
    defmodule Fake.Mod do
      @bound 5
      def kept(a, b), do: {a, b}
      defp hidden?(a), do: a
    end
    """

    test "does not depend on where the function sits in the file" do
      for padding <- [0, 10, 500] do
        source = String.duplicate("# filler\n", padding) <> @source
        index = %{"Fake.Mod" => source}

        assert citation_problem(index, "Fake.Mod", "kept", []) == nil
        assert citation_problem(index, "Fake.Mod", "kept", ["2"]) == nil
        assert citation_problem(index, "Fake.Mod", "hidden?", []) == nil
        assert citation_problem(index, "Fake.Mod", "bound", []) == nil
      end
    end

    test "flags a missing function, wrong arity, or unknown module" do
      index = %{"Fake.Mod" => @source}

      assert citation_problem(index, "Fake.Mod", "gone", [])
      assert citation_problem(index, "Fake.Mod", "kept", ["3"])
      assert citation_problem(index, "Fake.Nope", "kept", [])
    end
  end

  # %{"Mod.Name" => source} for every module defined under apps/*/lib.
  defp module_index do
    for file <- Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex")),
        source = File.read!(file),
        [_, module] <- Regex.scan(~r/^\s*defmodule ([\w.]+) do/m, source),
        into: %{},
        do: {module, source}
  end

  defp citation_problem(index, module, name, rest) do
    case Map.fetch(index, module) do
      :error ->
        "module #{module} not found under apps/*/lib"

      {:ok, source} ->
        n = Regex.escape(name)

        defined? =
          case rest do
            [arity] ->
              arity_defined?(source, n, String.to_integer(arity))

            [] ->
              definition?(source, n) or Regex.match?(~r/(?<![\w@.])#{n}(?![\w?!])/, source)
          end

        unless defined?, do: "#{name} is not defined in #{module}"
    end
  end

  # A def/defmacro/defguard head or a `@attr` of that name.
  defp definition?(source, n) do
    Regex.match?(
      ~r/^\s*(?:defp?|defmacrop?|defguardp?)\s+#{n}(?![\w?!])|^\s*@#{n}(?![\w?!])/m,
      source
    )
  end

  # def/defp heads with the given name whose top-level argument count matches
  # (or whose trailing defaults make it reachable).
  defp arity_defined?(source, n, arity) do
    ~r/^\s*(?:defp?|defmacrop?)\s+#{n}(?![\w?!])(?:\(([^\n]*)\)|[\s,])/m
    |> Regex.scan(source)
    |> Enum.any?(fn
      [_, args] -> arg_count(args) == arity or String.contains?(args, "\\\\")
      [_] -> arity == 0
    end)
  end

  defp arg_count(args) do
    args
    |> String.replace(~r/\s+(when|do)\b.*$|\)\s*,?\s*do:.*$/, "")
    |> String.graphemes()
    |> Enum.reduce({0, 1, ""}, fn
      c, {depth, count, _} when c in ["(", "[", "{"] -> {depth + 1, count, c}
      c, {depth, count, _} when c in [")", "]", "}"] -> {depth - 1, count, c}
      ",", {0, count, _} -> {0, count + 1, ","}
      _, acc -> acc
    end)
    |> elem(1)
  end
end
