# Shared by every umbrella app's test/test_helper.exs (bd-90vo7y), via
#
#     Code.eval_file(Path.expand("../../../scripts/test_max_cases.exs", __DIR__))
#     |> elem(0) |> then(& &1.(System.get_env()))
#
# Evaluates to a 1-arity function, env map -> ExUnit.start/1 options. It is an
# anonymous function rather than a module so an umbrella-root `mix test`, which
# loads all four helpers into one VM, doesn't redefine a module four times.
#
# `ARB_TEST_MAX_CASES=N` sets ExUnit's `max_cases`. Unset, a worker session
# (`ARB_WORKER_BEAD_ID`, which the spawn env always injects) gets a quarter of
# the schedulers, min 2; ExUnit's own default (2x schedulers) caps three
# concurrent workers' suites into a swap storm. Developer and CI runs keep the
# ExUnit default. A bad value (non-integer, < 1) warns and falls back.
fn env ->
  worker_default = fn -> [max_cases: max(2, div(System.schedulers_online(), 4))] end

  fallback = fn ->
    if env["ARB_WORKER_BEAD_ID"] in [nil, ""], do: [], else: worker_default.()
  end

  case env["ARB_TEST_MAX_CASES"] do
    raw when raw in [nil, ""] ->
      fallback.()

    raw ->
      case Integer.parse(String.trim(raw)) do
        {n, ""} when n >= 1 ->
          [max_cases: n]

        _ ->
          IO.warn("ARB_TEST_MAX_CASES=#{inspect(raw)} is not an integer >= 1; using the default")
          fallback.()
      end
  end
end
