defmodule Arbiter.Sessions.TranscriptDistillationTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions.TranscriptDistillation
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.Sessions.Memory.Frontmatter
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
    test "reads transcript, emits anchored candidates and avoids shared memory" do
      write_transcript(@session_id, "User: always use tabs\nAgent: I will use tabs")

      shared_dir = Layout.memory_shared_dir(@session_id)
      File.mkdir_p!(shared_dir)
      initial_shared = File.ls!(shared_dir)

      invoker = fn _prompt, _opts ->
        reply = """
        Here is the distilled memory.
        ```markdown
        ---
        name: tabs_preference
        description: User prefers tabs
        metadata:
          type: user
        source_transcript: wrong_session_id
        ---
        User prefers tabs.
        ```
        ```markdown
        ---
        name: -bad*name--collision
        description: desc
        metadata:
          type: user
        ---
        Collision 1.
        ```
        ```markdown
        ---
        name: -bad*name--collision
        description: desc
        metadata:
          type: user
        ---
        Collision 2.
        ```
        ```markdown
        ---
        name: missing_fields
        metadata:
          type: user
        ---
        This should be dropped.
        ```
        """

        {:ok, reply, %{model: "test-model", tokens_in: 100, cost_usd: 0.05}}
      end

      assert {:ok, candidates} =
               TranscriptDistillation.run(@session_id, invoker: invoker, workspace_id: "ws_123")

      assert length(candidates) == 3

      # shared memory must be untouched
      assert File.ls!(shared_dir) == initial_shared

      # Candidate files exist and Promotion queue can list them
      dir = Layout.memory_candidates_dir(@session_id)
      files = File.ls!(dir)
      assert length(files) == 3

      assert Enum.any?(files, &(&1 == "tabs_preference.md"))
      assert Enum.any?(files, &(&1 == "bad_name--collision.md"))
      assert Enum.count(files, &String.starts_with?(&1, "bad_name--collision_")) == 1

      # Ensure it's listed by Promotion
      promotable = Promotion.list_candidates() |> Enum.filter(&(&1.session_id == @session_id))
      assert length(promotable) == 3

      # Check anchoring in the output
      content = File.read!(Path.join(dir, "tabs_preference.md"))
      fields = Frontmatter.fields(content)
      assert fields["source_transcript"] == @session_id
      assert fields["turn_range"] == "0-44"

      # Cost is metered
      costs = Ash.read!(Event)
      assert length(costs) == 1
      cost = hd(costs)
      assert cost.session_id == @session_id
      assert cost.provider == "claude"
      assert cost.model == "test-model"
    end

    test ":max_bytes limits the prompt size" do
      write_transcript(@session_id, "1234567890")

      invoker = fn prompt, _opts ->
        assert prompt =~ "67890"
        refute prompt =~ "12345"
        {:ok, "```markdown\n---\nname: t\ndescription: d\ntype: t\n---\n```", %{}}
      end

      assert {:ok, [_]} = TranscriptDistillation.run(@session_id, invoker: invoker, max_bytes: 5)
    end

    test "handles invoker error" do
      write_transcript(@session_id, "hello")

      invoker = fn _, _ -> {:error, :timeout} end

      assert {:error, :timeout} = TranscriptDistillation.run(@session_id, invoker: invoker)
    end

    test "empty transcript returns early" do
      assert {:ok, []} = TranscriptDistillation.run("empty_session")
    end
  end
end
