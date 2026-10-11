defmodule Arbiter.Test.ScriptedOpenAI do
  @moduledoc """
  A scripted OpenAI-compatible `/v1/chat/completions` fixture server on a loopback
  port (bd-96ddf6, Q9). It stands in for the model endpoint behind the qwen CLI
  (`OPENAI_BASE_URL`) so a run is deterministic: each request consumes the next
  step of the script.

  Steps:

    * `{:text, "hi"}` — an assistant message, `finish_reason: "stop"`.
    * `{:text, ["hel", "lo"]}` — the same, delivered as these content deltas when
      the request has `stream: true` (joined into one message otherwise).
    * `{:tool_calls, [%{name: "read_file", arguments: %{"path" => "a"}}]}` — one
      `tool_calls` message, `finish_reason: "tool_calls"`. An `:id` is optional.
    * `{:error, status, message}` — an OpenAI-shaped error body with that status.
    * `{:rate_limit, retry_after_seconds}` — a 429 with a `retry-after` header.
    * `{:sleep, ms}` — not a response: waits `ms` before the *next* response step
      of the same request (use it to exercise client timeouts).

  `stream: true` requests get Server-Sent Events (`data: {chunk}` … `data: [DONE]`),
  others a single JSON body. A request arriving after the script is exhausted
  gets a 500 `script_exhausted` error so an over-calling client fails loudly.

  Every request is recorded; read them back with `requests/1`.
  """

  alias Arbiter.Test.ScriptedOpenAI.Router

  @type step ::
          {:text, String.t() | [String.t()]}
          | {:tool_calls, [map()]}
          | {:error, pos_integer(), String.t()}
          | {:rate_limit, non_neg_integer()}
          | {:sleep, non_neg_integer()}

  @type t :: %{url: String.t(), port: :inet.port_number(), agent: pid()}

  @doc """
  Starts the server under the calling test's supervisor (`ExUnit.Callbacks.start_supervised!/1`).
  `url` is the OpenAI base URL (ends in `/v1`).
  """
  @spec start_supervised!([step()]) :: t()
  def start_supervised!(steps) do
    agent =
      ExUnit.Callbacks.start_supervised!(%{
        id: {__MODULE__, :script, make_ref()},
        start: {Agent, :start_link, [fn -> %{steps: steps, requests: []} end]}
      })

    bandit =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {Router, agent}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {__MODULE__, :http, make_ref()}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    %{url: "http://127.0.0.1:#{port}/v1", port: port, agent: agent}
  end

  @doc "Requests received so far, oldest first: `%{path:, headers:, body: decoded_json}`."
  @spec requests(t()) :: [map()]
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Steps not yet consumed."
  @spec remaining(t()) :: [step()]
  def remaining(%{agent: agent}), do: Agent.get(agent, & &1.steps)

  @doc false
  @spec record(pid(), map()) :: :ok
  def record(agent, request), do: Agent.update(agent, &%{&1 | requests: [request | &1.requests]})

  @doc false
  # Pops leading `:sleep` steps (returning their total) and then one response step.
  @spec next(pid()) :: {non_neg_integer(), step() | :exhausted}
  def next(agent) do
    Agent.get_and_update(agent, fn %{steps: steps} = state ->
      {sleeps, rest} = Enum.split_while(steps, &match?({:sleep, _}, &1))
      delay = sleeps |> Enum.map(fn {:sleep, ms} -> ms end) |> Enum.sum()

      case rest do
        [] -> {{delay, :exhausted}, %{state | steps: []}}
        [step | tail] -> {{delay, step}, %{state | steps: tail}}
      end
    end)
  end
end
