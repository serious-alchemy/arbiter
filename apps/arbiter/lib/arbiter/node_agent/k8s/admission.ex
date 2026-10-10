defmodule Arbiter.NodeAgent.K8s.Admission do
  @moduledoc """
  The controller's **second admission gate** and the `hb.capacity` it reports
  (`docs/design/remote-workers.md` K§4.2). Pure, over facts the controller gathers:

    * `max_concurrent`: the ceiling from the ConfigMap;
    * `running`, `pending`: runs holding a slot (`pending` = waiting on the
      scheduler or still starting, `running` = the worker is up or terminating);
    * `unschedulable`: how many of the pending ones the scheduler said no to;
    * `headroom`: pods that fit the `ResourceQuota`
      (`Arbiter.NodeAgent.K8s.Quota`): an integer, `:unbounded`, or `:unknown`
      when the quota could not be read;
    * `draining?`.

  The primary's `Placement` has already reserved a slot against the effective
  maximum (gate one); this re-checks on `assign`:
  `running + pending < max_concurrent` **and** `headroom >= 1`, else
  `{:refuse, :no_capacity, detail}`, which the primary treats as a hold.
  An unreadable quota refuses too: admitting blind could push the namespace over
  a quota that then 403s every create.
  """

  @type facts :: %{
          required(:max_concurrent) => pos_integer(),
          required(:running) => non_neg_integer(),
          required(:pending) => non_neg_integer(),
          required(:headroom) => non_neg_integer() | :unbounded | :unknown,
          optional(:unschedulable) => non_neg_integer(),
          optional(:draining?) => boolean()
        }

  @spec decide(facts()) :: :ok | {:refuse, :no_capacity, String.t()}
  def decide(facts) do
    held = facts.running + facts.pending

    cond do
      Map.get(facts, :draining?, false) ->
        {:refuse, :no_capacity, "controller is draining"}

      held >= facts.max_concurrent ->
        {:refuse, :no_capacity,
         "#{held} of max_concurrent #{facts.max_concurrent} runs already hold a slot"}

      facts.headroom == :unknown ->
        {:refuse, :no_capacity, "ResourceQuota could not be read"}

      facts.headroom == 0 ->
        {:refuse, :no_capacity, "no ResourceQuota headroom for another pod"}

      true ->
        :ok
    end
  end

  @doc """
  The `hb.capacity` map: `ceiling, running, pending, headroom, constrained`.
  `headroom` is the quota's (an unbounded quota reports what the ceiling leaves);
  `constrained` says a run is waiting on the scheduler or the quota is exhausted,
  which makes `Placement` rank the node last.
  """
  @spec capacity(facts()) :: %{String.t() => term()}
  def capacity(facts) do
    left = max(facts.max_concurrent - facts.running - facts.pending, 0)

    %{
      "ceiling" => facts.max_concurrent,
      "running" => facts.running,
      "pending" => facts.pending,
      "headroom" => wire_headroom(facts.headroom, left),
      "constrained" => Map.get(facts, :unschedulable, 0) > 0 or facts.headroom == 0
    }
  end

  defp wire_headroom(n, _left) when is_integer(n), do: n
  defp wire_headroom(:unbounded, left), do: left
  defp wire_headroom(:unknown, _left), do: 0
end
