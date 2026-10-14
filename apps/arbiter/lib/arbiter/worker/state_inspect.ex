defimpl Inspect, for: Arbiter.Worker.State do
  # bd-akp9ae: a Worker's state, printed anywhere (a log line, the arguments in a crash
  # report's stacktrace), masks the secrets it holds (`Arbiter.Worker.StateRedaction`).
  def inspect(state, opts) do
    state
    |> Arbiter.Worker.StateRedaction.mask()
    |> Inspect.Any.inspect(opts)
  end
end
