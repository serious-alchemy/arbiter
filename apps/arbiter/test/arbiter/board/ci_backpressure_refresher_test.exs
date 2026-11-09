defmodule Arbiter.Board.CiBackpressure.RefresherTest do
  @moduledoc """
  The timer behind the CI backpressure gate: it polls every gated repo whether or
  not a card is queued, so the first card promoted after a quiet spell finds a
  fresh reading instead of `:unknown` or a stale one.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.CiBackpressure
  alias Arbiter.Board.CiBackpressure.Refresher
  alias Arbiter.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])

    ws =
      Ash.create!(Workspace, %{
        name: "cibr-#{n}",
        prefix: "cibr#{n}",
        config: %{
          "worker" => %{
            "repos" => %{"vstim" => %{"ci_backpressure" => %{"max_pending" => 4}}}
          }
        }
      })

    %{ws: ws}
  end

  test "a tick polls the gated repo with no card queued", %{ws: ws} do
    test = self()

    poller = fn %{id: id}, "vstim" ->
      send(test, {:polled, id})
      {:ok, %{pending: 7, oldest_at: nil}}
    end

    pid =
      start_supervised!(
        {Refresher,
         name: nil,
         enabled: true,
         interval_ms: :never,
         refresh_opts: [poller: poller, async: false]}
      )

    send(pid, :tick)
    _ = :sys.get_state(pid)

    assert_received {:polled, ws_id}
    assert ws_id == ws.id

    # The card promoted afterwards is held on that reading, with no new poll.
    never = fn _ws, _repo -> flunk("must not poll again") end

    issue = %{
      id: "t-1",
      state: :queued,
      priority: 2,
      issue_type: :feature,
      workspace_id: ws.id,
      repo: "vstim"
    }

    assert %{"t-1" => {:hold, "7 pending"}} =
             CiBackpressure.holds([ws], [issue], poller: never, async: true)
  end

  test "init/1 reports :ignore when disabled" do
    assert Refresher.init(enabled: false) == :ignore
  end
end
