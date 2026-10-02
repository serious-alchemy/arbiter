defmodule Arbiter.Sessions.TranscriptDistillationTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions.TranscriptDistillation
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Transcript
  alias Arbiter.Usage.Event

  @moduletag :tmp_dir

  @session_id "test_distill_session"

  setup %{tmp_dir: tmp_dir} do
    prior = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, tmp_dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, :sessions_root, prior),
        else: Application.delete_env(:arbiter, :sessions_root)
    end)

    {:ok, root: tmp_dir}
  end

  defp write_transcript(session_id, data) do
    Transcript.append(session_id, data)
  end

  describe "run/2" do
    test "reads transcript, invokes model, emits candidates and writes cost" do
      write_transcript(@session_id, "User: always use tabs\nAgent: I will use tabs")

      invoker = fn prompt, _opts ->
        assert prompt =~ "User: always use tabs"

        reply = """
        Here is the distilled memory.
        ```markdown
        ---
        name: tabs_preference
        description: User prefers tabs
        metadata:
          type: user
        source_transcript: test_distill_session
        turn_range: 1-2
        ---
        User prefers tabs.
        ```
        """

        {:ok, reply, %{model: "test-model", tokens_in: 100, cost_usd: 0.05}}
      end

      assert {:ok, candidates} =
               TranscriptDistillation.run(@session_id, invoker: invoker, workspace_id: "ws_123")

      assert length(candidates) == 1

      # Candidate file exists
      dir = Layout.memory_candidates_dir(@session_id)
      files = File.ls!(dir)
      assert length(files) == 1
      assert hd(files) == "tabs_preference.md"

      content = File.read!(Path.join(dir, hd(files)))
      assert content =~ "turn_range: 1-2"

      # Cost is metered
      costs = Ash.read!(Event)
      assert length(costs) == 1
      cost = hd(costs)
      assert cost.session_id == @session_id
      assert cost.source == :coordinator_session
      assert cost.step == :other
      assert cost.model == "test-model"
      assert cost.cost_usd == 0.05
      assert cost.workspace_id == "ws_123"
    end

    test "empty transcript returns early" do
      assert {:ok, []} = TranscriptDistillation.run("empty_session")
    end
  end
end
