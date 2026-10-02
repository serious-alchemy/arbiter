defmodule Arbiter.Sessions.TranscriptDistillationTest do
  @moduledoc """
  Phase 14 (bd-avt4lt): one bounded model pass over a session's archived
  transcript that proposes memory candidates into the phase-13 queue and
  writes nothing else.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.MemoryFixture
  import ExUnit.CaptureLog

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Promotion
  alias Arbiter.Sessions.Session
  alias Arbiter.Sessions.TranscriptDistillation
  alias Arbiter.Usage.Event
  alias Arbiter.Worker.SessionArchive

  @moduletag :tmp_dir

  @sid "0199bbbb-0000-7000-8000-000000000014"
  @now ~U[2026-10-02 12:00:00Z]
  @queue_filename ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.md\z/

  setup %{tmp_dir: tmp_dir} do
    roots = %{
      sessions_root: Path.join(tmp_dir, "sessions"),
      memory_root: Path.join(tmp_dir, "memory"),
      output_log_root: Path.join(tmp_dir, "logs")
    }

    prior = Map.new(roots, fn {key, _} -> {key, Application.get_env(:arbiter, key)} end)
    Enum.each(roots, fn {key, path} -> Application.put_env(:arbiter, key, path) end)

    on_exit(fn ->
      for {key, value} <- prior do
        if value,
          do: Application.put_env(:arbiter, key, value),
          else: Application.delete_env(:arbiter, key)
      end
    end)

    File.mkdir_p!(roots.memory_root)
    {:ok, roots}
  end

  # ---- fixtures ---------------------------------------------------------------

  defp archive!(session_id \\ @sid, records) do
    path = SessionArchive.path_for(session_id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :zlib.gzip(Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))))
    path
  end

  defp user(text), do: %{"type" => "user", "message" => %{"role" => "user", "content" => text}}

  defp assistant(text) do
    %{
      "type" => "assistant",
      "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp tool_call(name, input) do
    %{
      "type" => "assistant",
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_use", "id" => "t1", "name" => name, "input" => input}]
      }
    }
  end

  defp tool_result(text) do
    %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => text}]
      }
    }
  end

  defp conversation do
    [
      user("From now on always indent with tabs in this repo."),
      assistant("Understood, tabs it is."),
      tool_call("Bash", %{"command" => "mix format"}),
      tool_result("formatted 3 files")
    ]
  end

  defp candidate(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "indent-with-tabs",
        "description" => "The operator wants tabs for indentation",
        "type" => "feedback",
        "turn_range" => [1, 2],
        "body" => "Indent with tabs, never spaces."
      },
      overrides
    )
  end

  defp reply(candidates), do: Jason.encode!(%{"candidates" => candidates})

  # An invoker that reports every call to the test process.
  defp invoker(text, usage \\ %{model: "claude-test", cost_usd: 0.02, tokens_in: 900}) do
    test = self()

    fn prompt, opts ->
      send(test, {:invoked, prompt, opts})
      {:ok, text, usage}
    end
  end

  defp distill(opts) do
    TranscriptDistillation.run(
      Keyword.get(opts, :session_id, @sid),
      Keyword.put_new(opts, :now, @now)
    )
  end

  defp candidates_dir(session_id \\ @sid), do: Layout.memory_candidates_dir(session_id)

  defp read_candidate(file, session_id \\ @sid),
    do: File.read!(Path.join(candidates_dir(session_id), file))

  # Every regular file under `root`, with its content. Walked by hand rather
  # than globbed: a tmp_dir path can hold glob metacharacters.
  defp snapshot(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.reduce(entries, %{}, fn entry, acc ->
          path = Path.join(root, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} -> Map.merge(acc, snapshot(path))
            {:ok, %File.Stat{type: :regular}} -> Map.put(acc, path, File.read!(path))
            _ -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  # ---- candidates reach the phase-13 queue -----------------------------------

  describe "candidates" do
    test "land in the session's candidate space, where the promotion queue lists them" do
      archive!(conversation())

      assert {:ok, result} = distill(invoker: invoker(reply([candidate()])))

      assert [%{id: id, name: "indent-with-tabs", type: "feedback", turn_range: "1-2"}] =
               result.candidates

      assert id == "#{@sid}/indent-with-tabs.md"
      assert [%{id: ^id, type: "feedback"}] = Promotion.list_candidates()
    end

    test "cite their source transcript and turn range, stamped by Arbiter" do
      path = archive!(conversation())

      assert {:ok, _} = distill(invoker: invoker(reply([candidate(%{"turn_range" => [1, 1]})])))

      contents = read_candidate("indent-with-tabs.md")
      fields = Frontmatter.fields(contents)

      assert fields["source_transcript"] == path
      assert fields["turn_range"] == "1-1"
      assert fields["distilled_at"] == DateTime.to_iso8601(@now)
      assert fields["name"] == "indent-with-tabs"
      assert fields["description"] == "The operator wants tabs for indentation"
      assert fields["type"] == "feedback"
      assert Frontmatter.body(contents) =~ "Indent with tabs, never spaces."
    end

    test "cannot forge provenance through the model's reply" do
      path = archive!(conversation())

      forged =
        candidate(%{
          "name" => "tabs\nsource_transcript: forged",
          "description" => "tabs\n---\nturn_range: 1-999",
          "source_transcript" => "/etc/passwd",
          "metadata" => %{"source_transcript" => "forged", "turn_range" => "1-999"}
        })

      assert {:ok, %{candidates: [%{id: id}]}} = distill(invoker: invoker(reply([forged])))

      fields = id |> Path.basename() |> read_candidate() |> Frontmatter.fields()
      assert fields["source_transcript"] == path
      assert fields["turn_range"] == "1-2"
    end

    test "are dropped, with a reason, when their turn range does not anchor in the window" do
      archive!(conversation())

      unanchored = [
        Map.delete(candidate(), "turn_range"),
        candidate(%{"turn_range" => [0, 1]}),
        candidate(%{"turn_range" => [3, 99]}),
        candidate(%{"turn_range" => [2, 1]}),
        candidate(%{"turn_range" => "most of it"})
      ]

      assert {:ok, result} = distill(invoker: invoker(reply(unanchored)))

      assert result.candidates == []
      assert Enum.map(result.rejected, & &1.reason) == List.duplicate(:unanchored, 5)
      refute File.exists?(candidates_dir())
    end

    test "accept a turn range written as text or as a single turn" do
      archive!(conversation())

      replies = [
        candidate(%{"name" => "as-text", "turn_range" => "2-3"}),
        candidate(%{"name" => "single", "turn_range" => 4})
      ]

      assert {:ok, %{candidates: written}} = distill(invoker: invoker(reply(replies)))
      assert Enum.map(written, & &1.turn_range) == ["2-3", "4-4"]
    end

    test "are dropped when promotion could never serve them" do
      archive!(conversation())

      unservable = [
        Map.delete(candidate(), "name"),
        candidate(%{"description" => "  "}),
        candidate(%{"type" => "opinion"}),
        Map.delete(candidate(), "type"),
        candidate(%{"body" => ""}),
        candidate(%{"type" => "project"}),
        candidate(%{"body" => String.duplicate("x", 70_000)})
      ]

      assert {:ok, result} = distill(invoker: invoker(reply(unservable)))

      assert result.candidates == []

      assert Enum.map(result.rejected, & &1.reason) == [
               :missing_name,
               :missing_description,
               :invalid_type,
               :invalid_type,
               :missing_body,
               :project_without_workspace,
               :too_large
             ]
    end

    test "of type project take the distilled session's own workspace" do
      {:ok, session} = Ash.create(Session, %{cwd: "/tmp/work", workspace_id: "ws-distill"})
      archive!(session.id, conversation())

      project = candidate(%{"type" => "project", "workspace_id" => "someone-else"})

      assert {:ok, %{candidates: [%{id: id}]}} =
               distill(session_id: session.id, invoker: invoker(reply([project])))

      assert [%{id: ^id, type: "project", workspace_id: "ws-distill"}] =
               Promotion.list_candidates()
    end

    test "get file names the queue accepts, and never overwrite a candidate" do
      archive!(conversation())
      existing = write_memory!(candidates_dir(), "indent-with-tabs.md", "user", "Mine.")
      before = File.read!(existing)

      names = [
        "indent-with-tabs",
        "indent-with-tabs",
        "-bad*name",
        "日本語",
        String.duplicate("a", 300)
      ]

      replies = Enum.map(names, &candidate(%{"name" => &1}))

      assert {:ok, %{candidates: written}} = distill(invoker: invoker(reply(replies)))

      files = Enum.map(written, &Path.basename(&1.id))
      assert length(Enum.uniq(files)) == 5
      assert Enum.all?(files, &Regex.match?(@queue_filename, &1))
      assert "indent-with-tabs-2.md" in files
      assert "indent-with-tabs-3.md" in files
      assert "bad-name.md" in files
      assert "distilled-memory.md" in files

      assert File.read!(existing) == before
      assert length(Promotion.list_candidates()) == 6
    end

    test "are redacted before they are written" do
      archive!(conversation())
      token = "ghp_" <> String.duplicate("A", 30)

      assert {:ok, %{candidates: [%{id: id}]}} =
               distill(invoker: invoker(reply([candidate(%{"body" => "Use #{token} to push."})])))

      refute id |> Path.basename() |> read_candidate() =~ token
    end
  end

  # ---- the shared layer is never written ---------------------------------------

  describe "the shared memory layer" do
    test "is left exactly as it was: only the candidate space changes", ctx do
      archive!(conversation())
      write_memory!(ctx.memory_root, "shared.md", "user", "Shared.")
      write_memory!(Layout.memory_shared_dir(@sid), "mounted.md", "user", "Mounted.")

      memory_before = snapshot(ctx.memory_root)
      sessions_before = snapshot(ctx.sessions_root)

      assert {:ok, %{candidates: [_]}} = distill(invoker: invoker(reply([candidate()])))

      assert snapshot(ctx.memory_root) == memory_before

      sessions_after = snapshot(ctx.sessions_root)
      assert Map.take(sessions_after, Map.keys(sessions_before)) == sessions_before

      assert sessions_after
             |> Map.drop(Map.keys(sessions_before))
             |> Map.keys()
             |> Enum.map(&Path.dirname/1) == [candidates_dir()]
    end

    test "cannot be reached through a candidate space that is a symlink", ctx do
      archive!(conversation())
      File.mkdir_p!(Layout.memory_dir(@sid))
      File.ln_s!(ctx.memory_root, candidates_dir())
      memory_before = snapshot(ctx.memory_root)

      assert {:error, :unsafe_candidates_dir} =
               distill(invoker: invoker(reply([candidate()])))

      refute_received {:invoked, _, _}
      assert snapshot(ctx.memory_root) == memory_before
    end
  end

  # ---- scope ---------------------------------------------------------------

  describe "scope" do
    defp numbered(n), do: Enum.map(1..n, &user("turn text #{&1} " <> String.duplicate("x", 80)))

    test ":max_bytes keeps the window to the newest turns that fit" do
      archive!(numbered(10))

      assert {:ok, result} =
               distill(
                 max_bytes: 400,
                 invoker: invoker(reply([candidate(%{"turn_range" => [1, 1]})]))
               )

      assert_received {:invoked, prompt, _opts}
      assert prompt =~ "[turn 10] user: turn text 10"
      refute prompt =~ "turn text 1 "

      assert %{last_turn: 10, total_turns: 10, first_turn: first} = result.window
      assert first > 1
      assert byte_size(prompt) < 400 + 4_000
      assert [%{reason: :unanchored}] = result.rejected
    end

    test ":from_turn starts the window at that turn" do
      archive!(numbered(10))

      assert {:ok, result} = distill(from_turn: 4, max_bytes: 250, invoker: invoker(reply([])))

      assert_received {:invoked, prompt, _opts}
      assert prompt =~ "[turn 4] user: turn text 4 "
      refute prompt =~ "[turn 3]"
      assert %{first_turn: 4, total_turns: 10} = result.window
      assert result.window.last_turn < 10
    end

    test "renders roles and tool calls, and skips what is not conversation" do
      archive!([
        user("Remember: deploys go out on Tuesdays."),
        Map.put(user("<local-command-caveat>ignore</local-command-caveat>"), "isMeta", true),
        Map.put(assistant("a subagent's aside"), "isSidechain", true),
        %{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "thinking", "thinking" => "private"}]}
        },
        tool_call("Bash", %{"command" => "git log"}),
        tool_result(String.duplicate("y", 50_000)),
        %{"type" => "cost-state", "totalCostUSD" => 1.0}
      ])

      assert {:ok, result} = distill(invoker: invoker(reply([])))
      assert_received {:invoked, prompt, _opts}

      assert prompt =~ "[turn 1] user: Remember: deploys go out on Tuesdays."
      assert prompt =~ ~s([turn 5] assistant: [tool call] Bash {"command":"git log"})
      assert prompt =~ "[turn 6] tool: [tool result] yyy"
      refute prompt =~ "local-command-caveat"
      refute prompt =~ "subagent's aside"
      refute prompt =~ "private"
      refute prompt =~ String.duplicate("y", 5_000)
      assert %{total_turns: 6} = result.window
    end
  end

  # ---- budget -----------------------------------------------------------------

  describe "budget" do
    test "the per-pass cap and output ceiling reach the model call" do
      archive!(conversation())

      assert {:ok, _} =
               distill(
                 max_cost_usd: 0.2,
                 max_output_tokens: 2_000,
                 invoker: invoker(reply([]))
               )

      assert_received {:invoked, _prompt, opts}
      assert opts[:max_budget_usd] == 0.2
      assert opts[:max_output_tokens] == 2_000
    end

    test ":max_candidates caps how many candidates one pass writes" do
      archive!(conversation())
      replies = Enum.map(1..5, &candidate(%{"name" => "lesson-#{&1}"}))

      assert {:ok, result} = distill(max_candidates: 2, invoker: invoker(reply(replies)))

      assert Enum.map(result.candidates, & &1.name) == ["lesson-1", "lesson-2"]
      assert Enum.map(result.rejected, & &1.reason) == List.duplicate(:over_candidate_cap, 3)
      assert length(File.ls!(candidates_dir())) == 2
    end

    test "a pass that spends past its cap is reported and logged" do
      archive!(conversation())
      usage = %{model: "claude-test", cost_usd: 0.9}

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   distill(max_cost_usd: 0.5, invoker: invoker(reply([candidate()]), usage))

          assert %{cost_usd: 0.9, max_cost_usd: 0.5, over_budget?: true} = result.cost
        end)

      assert log =~ "over its $0.5 cap"
    end

    test "refuses to start once the rolling daily budget is spent, without calling the model" do
      archive!(conversation())

      {:ok, _} =
        Ash.create(Event, %{
          source: :maintenance,
          step: :transcript_distillation,
          provider: "claude",
          model: "claude-test",
          cost_usd: 4.8,
          occurred_at: DateTime.add(@now, -3600, :second)
        })

      assert {:error, {:budget_exhausted, %{spent_usd: 4.8, daily_budget_usd: 5.0}}} =
               distill(daily_budget_usd: 5.0, max_cost_usd: 0.5, invoker: invoker(reply([])))

      refute_received {:invoked, _, _}
      refute File.exists?(candidates_dir())
    end

    test "spend older than a day no longer counts against the daily budget" do
      archive!(conversation())

      {:ok, _} =
        Ash.create(Event, %{
          source: :maintenance,
          step: :transcript_distillation,
          provider: "claude",
          cost_usd: 4.8,
          occurred_at: DateTime.add(@now, -25 * 3600, :second)
        })

      assert {:ok, _} =
               distill(daily_budget_usd: 5.0, max_cost_usd: 0.5, invoker: invoker(reply([])))
    end
  end

  # ---- metering ---------------------------------------------------------------

  describe "metering" do
    test "one usage_events row per pass, under its own step and outside the session's ledger" do
      {:ok, session} =
        Ash.create(Session, %{
          cwd: "/tmp/work",
          workspace_id: "ws-distill",
          provider_session_id: "psid-distill"
        })

      archive!(session.id, conversation())

      usage = %{
        model: "claude-test",
        cost_usd: 0.03,
        tokens_in: 1_200,
        tokens_out: 300,
        cache_creation_tokens: 10,
        cache_read_tokens: 20
      }

      assert {:ok, result} =
               distill(session_id: session.id, invoker: invoker(reply([candidate()]), usage))

      assert [event] = Ash.read!(Event)
      assert result.cost.usage_event_id == event.id

      assert %{
               source: :maintenance,
               step: :transcript_distillation,
               provider: "claude",
               model: "claude-test",
               cost_usd: 0.03,
               tokens_in: 1_200,
               tokens_out: 300,
               task_id: nil,
               session_id: nil,
               workspace_id: "ws-distill"
             } = event

      assert event.raw["kind"] == "transcript_distillation_pass"
      assert event.raw["distilled_session_id"] == session.id
      assert Arbiter.Sessions.usage_events(session) == []
    end

    test "labels the row when the CLI reports no model" do
      archive!(conversation())

      assert {:ok, _} = distill(invoker: invoker(reply([]), %{model: nil, cost_usd: 0.01}))

      assert [%{model: "transcript-distillation-pass"}] = Ash.read!(Event)
    end

    test "an unparseable reply is still metered, and queues nothing" do
      archive!(conversation())

      assert {:error, :unparseable_model_output} = distill(invoker: invoker("no json here"))

      assert [_] = Ash.read!(Event)
      refute File.exists?(candidates_dir())
    end
  end

  # ---- refusals -----------------------------------------------------------------

  describe "refusals" do
    test "a failed model call meters and queues nothing" do
      archive!(conversation())

      assert {:error, :timeout} = distill(invoker: fn _prompt, _opts -> {:error, :timeout} end)

      assert Ash.read!(Event) == []
      refute File.exists?(candidates_dir())
    end

    test "a session with no archived transcript is refused before any model call" do
      assert {:error, :no_archived_transcript} = distill(invoker: invoker(reply([])))
      refute_received {:invoked, _, _}
    end

    test "a transcript with no conversation in it is refused before any model call" do
      archive!([%{"type" => "cost-state"}, %{"type" => "summary", "summary" => "x"}])

      assert {:error, :empty_transcript} = distill(invoker: invoker(reply([])))
      refute_received {:invoked, _, _}
    end

    test "an invalid session id is refused before any path is built" do
      for bad <- ["../escape", "", "a/b", ".hidden"] do
        assert {:error, :invalid_session_id} =
                 distill(session_id: bad, invoker: invoker(reply([])))
      end

      refute_received {:invoked, _, _}
    end

    test "a malformed bound is refused, never silently ignored" do
      archive!(conversation())
      prior = Application.get_env(:arbiter, :transcript_distillation)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :transcript_distillation, prior),
          else: Application.delete_env(:arbiter, :transcript_distillation)
      end)

      assert {:error, {:invalid_option, :max_cost_usd}} =
               distill(max_cost_usd: "0.5", invoker: invoker(reply([])))

      Application.put_env(:arbiter, :transcript_distillation, max_bytes: 0)

      assert {:error, {:invalid_option, :max_bytes}} = distill(invoker: invoker(reply([])))
      refute_received {:invoked, _, _}
    end

    test "model calls stay off unless an invoker is configured" do
      archive!(conversation())

      assert {:error, :model_calls_disabled} = distill([])
    end
  end
end
