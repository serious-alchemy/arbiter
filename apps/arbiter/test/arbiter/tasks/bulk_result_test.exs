defmodule Arbiter.Tasks.BulkResultTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.BulkResult

  describe "fetch_ids/1" do
    test "accepts a list of ids, trimmed and de-duplicated" do
      assert {:ok, ["a", "b"]} = BulkResult.fetch_ids(%{"ids" => [" a ", "b", "a"]})
    end

    test "rejects missing, empty and non-list ids" do
      assert {:error, _} = BulkResult.fetch_ids(%{})
      assert {:error, _} = BulkResult.fetch_ids(%{"ids" => []})
      assert {:error, _} = BulkResult.fetch_ids(%{"ids" => "a"})
      assert {:error, _} = BulkResult.fetch_ids(%{"ids" => [1]})
    end

    test "enforces the batch cap with a clear message" do
      ids = Enum.map(1..(BulkResult.max_batch() + 1), &"bd-#{&1}")
      assert {:error, msg} = BulkResult.fetch_ids(%{"ids" => ids})
      assert msg =~ "at most #{BulkResult.max_batch()}"
      assert {:ok, _} = BulkResult.fetch_ids(%{"ids" => Enum.take(ids, BulkResult.max_batch())})
    end
  end

  describe "run_rank/3" do
    defp steps(ids, args) do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      result =
        BulkResult.run_rank(ids, args, fn id, a ->
          Agent.update(agent, &[{id, a} | &1])
          {:ok, id}
        end)

      {Enum.map(result.results, & &1.id), agent |> Agent.get(& &1) |> Enum.reverse()}
    end

    test "top is applied in reverse so list order is preserved; results stay in input order" do
      assert {~w(a b c), calls} = steps(~w(a b c), %{"top" => true})
      assert Enum.map(calls, &elem(&1, 0)) == ~w(c b a)
    end

    test "after_id chains each id after the previous one" do
      assert {~w(a b c), calls} = steps(~w(a b c), %{"after_id" => "X"})

      assert Enum.map(calls, fn {id, a} -> {id, a["after_id"]} end) ==
               [{"a", "X"}, {"b", "a"}, {"c", "b"}]
    end

    test "bottom and before_id apply in list order" do
      assert {_, calls} = steps(~w(a b), %{"bottom" => true})
      assert Enum.map(calls, &elem(&1, 0)) == ~w(a b)
      assert {_, calls} = steps(~w(a b), %{"before_id" => "X"})
      assert Enum.map(calls, &elem(&1, 0)) == ~w(a b)
    end
  end

  describe "run/2" do
    test "classifies each id independently and counts them" do
      outcome = fn
        "ok" -> {:ok, %{"id" => "ok"}}
        "ref" -> {:error, {:invalid, "no acceptance"}}
        "gone" -> {:error, {:not_found, "task gone not found"}}
      end

      assert %{results: results, counts: counts} = BulkResult.run(~w(ok ref gone), outcome)

      assert [
               %{id: "ok", status: "ok", ticket: %{"id" => "ok"}},
               %{id: "ref", status: "refused", reason: "no acceptance"},
               %{id: "gone", status: "not_found", reason: "task gone not found"}
             ] = results

      refute Map.has_key?(Enum.at(results, 0), :reason)
      assert counts == %{total: 3, ok: 1, refused: 1, not_found: 1}
    end

    test "an Ash not-found error is not_found" do
      err = Ash.Error.to_ash_error(%Ash.Error.Query.NotFound{resource: Arbiter.Tasks.Issue})

      assert %{results: [%{status: "not_found"}]} =
               BulkResult.run(["x"], fn _ -> {:error, err} end)
    end
  end
end
