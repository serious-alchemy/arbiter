defmodule ArbiterCli.Cmd.ExitCodesTest do
  @moduledoc """
  bd-5fc29i (P-06): one exit-code contract — 3 when the server is unreachable,
  4 for an HTTP 404, 1 for any other refusal — held by every command, including
  the ones (`breaker`, `image`, `scheduler`, `queue`) that used to flatten the
  error to a string and exit 1.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.{Breaker, Image, Queue, Scheduler}

  # {label, method, path, run fun}
  @commands [
    {"breaker list", :get, "/api/breakers", &Breaker.run/1, ["list"]},
    {"breaker reset", :post, "/api/breakers/reset", &Breaker.run/1, ["reset", "sig"]},
    {"image list", :get, "/api/images", &Image.run/1, ["list"]},
    {"image build", :post, "/api/images/build", &Image.run/1, ["build", "some/repo"]},
    {"scheduler pause", :post, "/api/scheduler/pause", &Scheduler.run/1, ["pause"]},
    {"scheduler status", :get, "/api/scheduler/status", &Scheduler.run/1, ["status"]},
    {"queue retry-auto-resolve", :post, "/api/queue/bd-1/retry_auto_resolve", &Queue.run/1,
     ["retry-auto-resolve", "bd-1"]},
    {"queue restart-watchdog", :post, "/api/queue/bd-1/restart_watchdog", &Queue.run/1,
     ["restart-watchdog", "bd-1"]},
    {"queue rerun-ci", :post, "/api/queue/bd-1/rerun_ci", &Queue.run/1, ["rerun-ci", "bd-1"]},
    {"queue mark-ci-external", :post, "/api/queue/bd-1/mark_ci_external", &Queue.run/1,
     ["mark-ci-external", "bd-1", "infra"]}
  ]

  for {label, method, path, run, args} <- @commands do
    test "#{label}: a stopped server exits 3" do
      stub_transport_error(unquote(method), unquote(path), :econnrefused)

      {_out, err, code} = capture(fn -> unquote(run).(unquote(args)) end)

      assert code == 3, "expected exit 3, got #{code}; stderr: #{err}"
    end

    test "#{label}: a 404 exits 4" do
      stub_request(
        unquote(method),
        unquote(path),
        %{"error" => %{"type" => "not_found", "message" => "No ticket", "details" => %{}}},
        404
      )

      {_out, err, code} = capture(fn -> unquote(run).(unquote(args)) end)

      assert code == 4, "expected exit 4, got #{code}; stderr: #{err}"
    end

    test "#{label}: any other refusal exits 1" do
      stub_request(
        unquote(method),
        unquote(path),
        %{"error" => %{"type" => "conflict", "message" => "no", "details" => %{}}},
        409
      )

      {_out, _err, code} = capture(fn -> unquote(run).(unquote(args)) end)

      assert code == 1
    end
  end
end
