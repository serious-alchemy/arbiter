defmodule Arbiter.Mergers.Gitlab.BudgetTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab.Budget

  setup do
    Budget.reset()
    clock = start_supervised!({Agent, fn -> 1_000 end})
    sleeps = start_supervised!({Agent, fn -> [] end}, id: :sleeps)

    Application.put_env(:arbiter, :gitlab_budget_now_ms, fn -> Agent.get(clock, & &1) end)

    Application.put_env(:arbiter, :gitlab_budget_sleep, fn ms ->
      Agent.update(sleeps, &[ms | &1])
      Agent.update(clock, &(&1 + ms))
    end)

    on_exit(fn ->
      Application.delete_env(:arbiter, :gitlab_budget_now_ms)
      Application.delete_env(:arbiter, :gitlab_budget_sleep)
      Budget.reset()
    end)

    %{clock: clock, sleeps: sleeps}
  end

  defp counting_fetch(result) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fun = fn ->
      Agent.update(counter, &(&1 + 1))
      result
    end

    {fun, fn -> Agent.get(counter, & &1) end}
  end

  describe "path_lookup/3" do
    test "a repeated lookup for the same project hits the API once" do
      {fetch, calls} = counting_fetch({:ok, "g/p"})
      assert {:ok, "g/p"} = Budget.path_lookup("gl.test", "1", fetch)
      assert {:ok, "g/p"} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 1
      assert {:ok, "g/p"} = Budget.path_lookup("gl.test", "2", fetch)
      assert calls.() == 2
    end

    test "a 403 is negatively cached for its TTL, then retried", %{clock: clock} do
      {fetch, calls} = counting_fetch({:error, {:http_status, 403}})
      assert {:error, {:http_status, 403}, :fresh} = Budget.path_lookup("gl.test", "1", fetch)
      assert {:error, {:http_status, 403}, :cached} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 1

      Agent.update(clock, &(&1 + 59 * 60_000))
      assert {:error, _, :cached} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 1

      Agent.update(clock, &(&1 + 2 * 60_000))
      assert {:error, _, :fresh} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 2
    end

    test "a timeout is retried after its shorter TTL", %{clock: clock} do
      {fetch, calls} = counting_fetch({:error, {:error, :timeout}})
      assert {:error, _, :fresh} = Budget.path_lookup("gl.test", "1", fetch)
      assert {:error, _, :cached} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 1

      Agent.update(clock, &(&1 + 31_000))
      assert {:error, _, :fresh} = Budget.path_lookup("gl.test", "1", fetch)
      assert calls.() == 2
    end
  end

  describe "rate limiting" do
    test "a 429 with Retry-After delays the next request to that host", %{sleeps: sleeps} do
      resp = %Req.Response{status: 429, headers: %{"retry-after" => ["20"]}}
      assert {:ok, ^resp} = Budget.gate("gl.test", "GET /x", fn -> {:ok, resp} end)
      assert Agent.get(sleeps, & &1) == []

      ok = %Req.Response{status: 200}
      assert {:ok, ^ok} = Budget.gate("gl.test", "GET /x", fn -> {:ok, ok} end)
      assert [ms] = Agent.get(sleeps, & &1)
      assert ms >= 20_000

      assert {:ok, ^ok} = Budget.gate("gl.test", "GET /x", fn -> {:ok, ok} end)
      assert length(Agent.get(sleeps, & &1)) == 1
    end

    test "a 429 with RateLimit-Reset (epoch seconds) is honoured", %{sleeps: sleeps} do
      now_s = System.os_time(:second)

      resp = %Req.Response{status: 429, headers: %{"ratelimit-reset" => [to_string(now_s + 45)]}}
      Budget.gate("gl.test", "GET /x", fn -> {:ok, resp} end)
      Budget.gate("gl.test", "GET /x", fn -> {:ok, %Req.Response{status: 200}} end)
      assert [ms] = Agent.get(sleeps, & &1)
      assert ms >= 40_000
    end

    test "other hosts are not delayed", %{sleeps: sleeps} do
      resp = %Req.Response{status: 429, headers: %{"retry-after" => ["20"]}}
      Budget.gate("gl.test", "GET /x", fn -> {:ok, resp} end)
      Budget.gate("other.test", "GET /x", fn -> {:ok, %Req.Response{status: 200}} end)
      assert Agent.get(sleeps, & &1) == []
    end
  end

  describe "counters and snapshot" do
    test "counts requests per call site and records the last 429 and remaining budget" do
      ok = %Req.Response{status: 200, headers: %{"ratelimit-remaining" => ["77"]}}
      Budget.gate("gl.test", "GET /merge_requests/:id", fn -> {:ok, ok} end)
      Budget.gate("gl.test", "GET /merge_requests/:id", fn -> {:ok, ok} end)
      Budget.gate("gl.test", "POST /pipeline", fn -> {:ok, ok} end)

      snap = Budget.snapshot()
      assert snap.counts == %{"GET /merge_requests/:id" => 2, "POST /pipeline" => 1}
      assert snap.hosts["gl.test"].remaining == 77
      assert snap.hosts["gl.test"].last_429_at == nil

      Budget.gate("gl.test", "GET /x", fn -> {:ok, %Req.Response{status: 429}} end)
      assert %DateTime{} = Budget.snapshot().hosts["gl.test"].last_429_at
    end

    test "site/2 normalises numeric ids" do
      assert Budget.site(:get, "https://h/api/v4/projects/9/merge_requests/12/pipelines?x=1") ==
               "GET /api/v4/projects/:id/merge_requests/:id/pipelines"
    end

    test "doctor_check reports the last 429 time when one occurred" do
      assert %{severity: :ok} = Budget.doctor_check()
      Budget.gate("gl.test", "GET /x", fn -> {:ok, %Req.Response{status: 429}} end)
      check = Budget.doctor_check()
      assert check.severity == :warn
      assert check.detail =~ "last 429"
      assert check.detail =~ "gl.test"
    end
  end
end
