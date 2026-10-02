defmodule Arbiter.Sessions.Memory.StalenessTest do
  @moduledoc """
  The citation checks behind the phase-13 staleness checker (bd-19qve3),
  against real committed fixture repositories. Each rule has its positive
  control next to its failure case.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.MemoryFixture

  alias Arbiter.Sessions.Memory.Frontmatter
  alias Arbiter.Sessions.Memory.Staleness
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @short "defmodule Short do\n  def hello, do: :world\nend\n"

  defp citation(verdict, ref), do: Enum.find(verdict.citations, &(&1.ref == ref))

  # A promoted memory carries the anchors promotion recorded in its frontmatter.
  defp anchored(contents, verdict) do
    Frontmatter.put(contents, [{"anchors", Staleness.encode_anchors(verdict.anchors)}])
  end

  describe "file:line citations are content-anchored (amendment 1)" do
    test "an anchored citation still resolves after the code moves within the file" do
      checkout = checkout!(%{"lib/short.ex" => @short})
      contents = memory("project", "Greeting lives at lib/short.ex:2.")

      promoted =
        Staleness.verify_contents(contents, checkouts: [checkout], establish_anchors: true)

      assert promoted.status == :ok
      assert %{"lib/short.ex:2" => _hash} = promoted.anchors

      commit!(checkout, %{"lib/short.ex" => String.duplicate("# moved\n", 10) <> @short})

      verdict = Staleness.verify_contents(anchored(contents, promoted), checkouts: [checkout])

      assert verdict.status == :ok
      assert %{status: :ok, found_at: 12} = citation(verdict, "lib/short.ex:2")
    end

    test "a citation whose anchor text is gone is stale even though line N still exists" do
      checkout = checkout!(%{"lib/short.ex" => @short})
      contents = memory("project", "Greeting lives at lib/short.ex:2.")

      promoted =
        Staleness.verify_contents(contents, checkouts: [checkout], establish_anchors: true)

      commit!(checkout, %{"lib/short.ex" => String.replace(@short, ":world", ":mars")})

      verdict = Staleness.verify_contents(anchored(contents, promoted), checkouts: [checkout])

      assert verdict.status == :stale
      assert %{status: :anchor_missing} = citation(verdict, "lib/short.ex:2")
      assert Enum.any?(verdict.reasons, &(&1 =~ "lib/short.ex:2"))
    end

    test "a citation whose file is gone is stale" do
      checkout = checkout!(%{"lib/short.ex" => @short, "README.md" => "r\n"})
      contents = memory("project", "See lib/short.ex:2.")

      promoted =
        Staleness.verify_contents(contents, checkouts: [checkout], establish_anchors: true)

      commit!(checkout, %{"lib/short.ex" => :delete})

      verdict = Staleness.verify_contents(anchored(contents, promoted), checkouts: [checkout])

      assert verdict.status == :stale
      assert %{status: :file_missing} = citation(verdict, "lib/short.ex:2")
    end

    test "an unanchored citation is bounds-checked and anchored on first use" do
      checkout = checkout!(%{"lib/short.ex" => @short})

      ok = Staleness.verify_contents(memory("feedback", "lib/short.ex:2"), checkouts: [checkout])
      assert ok.status == :ok
      assert Map.has_key?(ok.anchors, "lib/short.ex:2")

      out =
        Staleness.verify_contents(memory("feedback", "lib/short.ex:99"), checkouts: [checkout])

      assert out.status == :stale
      assert %{status: :line_out_of_range} = citation(out, "lib/short.ex:99")
    end

    test "a recorded first-use anchor is honoured on the next check" do
      checkout = checkout!(%{"lib/short.ex" => @short})
      contents = memory("project", "lib/short.ex:2")
      first = Staleness.verify_contents(contents, checkouts: [checkout])

      commit!(checkout, %{"lib/short.ex" => "defmodule Short do\n  # gone\nend\n"})

      again = Staleness.verify_contents(contents, checkouts: [checkout], anchors: first.anchors)
      assert again.status == :stale
      assert %{status: :anchor_missing} = citation(again, "lib/short.ex:2")
    end

    test "reads the tree at HEAD, so an uncommitted file does not resolve" do
      checkout = checkout!(%{"lib/short.ex" => @short})
      File.write!(Path.join(checkout, "lib/scratch.ex"), "defmodule Scratch do\nend\n")

      verdict =
        Staleness.verify_contents(memory("project", "lib/scratch.ex:1"), checkouts: [checkout])

      assert %{status: :file_missing} = citation(verdict, "lib/scratch.ex:1")
    end

    test "records the HEAD sha of every checkout it verified against" do
      one = checkout!(%{"lib/short.ex" => @short})
      two = checkout!(%{"lib/other.ex" => "defmodule Other do\nend\n"})

      verdict =
        Staleness.verify_contents(memory("project", "lib/other.ex:1"), checkouts: [one, two])

      assert verdict.status == :ok
      assert verdict.checked_against == %{one => head!(one), two => head!(two)}
    end
  end

  describe "module citations" do
    test "a module under a workspace root must be defined; positive control resolves" do
      checkout =
        checkout!(%{
          "lib/short.ex" => "defmodule Short do\nend\n",
          "lib/short/module.ex" => "defmodule Short.Module do\nend\n"
        })

      ok =
        Staleness.verify_contents(memory("project", "Uses Short.Module."), checkouts: [checkout])

      assert ok.status == :ok
      assert %{kind: :module, status: :ok} = citation(ok, "Short.Module")

      gone =
        Staleness.verify_contents(memory("project", "Uses Short.Missing."), checkouts: [checkout])

      assert gone.status == :stale
      assert %{kind: :module, status: :undefined} = citation(gone, "Short.Missing")
    end

    test "dependency modules are mentions, not citations, backticked or not" do
      checkout = checkout!(%{"lib/short.ex" => @short})
      body = "Use Ecto.Changeset and `Phoenix.LiveView` here."

      verdict = Staleness.verify_contents(memory("project", body), checkouts: [checkout])

      assert verdict.status == :ok
      assert verdict.citations == []
    end

    # A repo that defines `Mix.Tasks.*` (this one has 28) does not own `Mix`,
    # and a nested `defmodule Config` does not make `Config` its namespace.
    test "an extended or nested namespace is not owned by the workspace" do
      checkout =
        checkout!(%{
          "lib/short.ex" => "defmodule Short do\n  defmodule Config do\n  end\nend\n",
          "lib/mix/tasks/short.run.ex" => "defmodule Mix.Tasks.Short.Run do\nend\n"
        })

      body = "Read Mix.Project.config/0 and Config.Reader, not Short.Gone."
      verdict = Staleness.verify_contents(memory("project", body), checkouts: [checkout])

      assert [%{ref: "Short.Gone", status: :undefined}] = verdict.citations
    end

    test "a nested module definition resolves by its full name" do
      nested = "defmodule Short do\n  defmodule Inner do\n  end\nend\n"
      checkout = checkout!(%{"lib/short.ex" => nested})

      verdict = Staleness.verify_contents(memory("project", "Short.Inner"), checkouts: [checkout])

      assert verdict.status == :ok
      assert %{status: :ok} = citation(verdict, "Short.Inner")
    end
  end

  describe "reference memories: internal pointers only (amendment 2)" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "memory-tickets", prefix: "memt"})

      # Only ids with a digit are treated as tickets (`Citations.tickets/2`), and
      # a random 6-char base36 id has none about 14% of the time.
      issue =
        Enum.find_value(1..30, fn _ ->
          {:ok, issue} = Ash.create(Issue, %{title: "cited", workspace_id: ws.id})
          if issue.id =~ ~r/^memt-.*\d/, do: issue
        end)

      {:ok, issue: issue}
    end

    test "ticket ids are verified against the ledger", %{issue: issue} do
      ok =
        Staleness.verify_contents(memory("reference", "Background: #{issue.id}."), checkouts: [])

      assert ok.status == :ok
      assert %{kind: :ticket, status: :ok} = citation(ok, issue.id)

      gone = Staleness.verify_contents(memory("reference", "See memt-9zz9zz."), checkouts: [])
      assert gone.status == :stale
      assert %{kind: :ticket, status: :missing} = citation(gone, "memt-9zz9zz")
    end

    test "external URLs are marked unchecked and never fetched or held against it" do
      body = "Runbook at https://unreachable.invalid/runbook (offline host)."

      verdict = Staleness.verify_contents(memory("reference", body), checkouts: [])

      assert verdict.status == :ok

      assert %{kind: :url, status: :unchecked} =
               citation(verdict, "https://unreachable.invalid/runbook")
    end
  end

  describe "user and feedback memories (amendment 7)" do
    test "with no citations they pass without touching any checkout" do
      verdict =
        Staleness.verify_contents(memory("feedback", "Prefer small PRs."),
          checkouts: ["/nonexistent/checkout"]
        )

      assert verdict.status == :ok
      assert verdict.checked_against == %{}
    end

    test "a stale file:line citation in one is caught the same way" do
      checkout = checkout!(%{"lib/short.ex" => @short})

      verdict =
        Staleness.verify_contents(memory("user", "My notes cite lib/gone.ex:3."),
          checkouts: [checkout]
        )

      assert verdict.status == :stale
      assert %{status: :file_missing} = citation(verdict, "lib/gone.ex:3")
    end

    test "ticket ids and URLs in one are not checked" do
      {:ok, _ws} = Ash.create(Workspace, %{name: "memory-fb", prefix: "memf"})
      body = "Learned in memf-9zz9zz; see https://example.com/post."

      verdict = Staleness.verify_contents(memory("feedback", body), checkouts: [])

      assert verdict.status == :ok
      assert verdict.citations == []
    end
  end

  describe "when nothing can be checked" do
    test "a cited file with no resolvable checkout is unverified, not stale" do
      verdict = Staleness.verify_contents(memory("project", "lib/short.ex:2"), checkouts: [])

      assert verdict.status == :unverified
      assert %{status: :unverifiable} = citation(verdict, "lib/short.ex:2")
    end

    test "a checkout that is not a git repository is skipped", %{} do
      not_git = Path.join(System.tmp_dir!(), "not-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(not_git)
      on_exit(fn -> File.rm_rf(not_git) end)

      verdict =
        Staleness.verify_contents(memory("project", "lib/short.ex:2"), checkouts: [not_git])

      assert verdict.status == :unverified
      assert verdict.checked_against == %{}
    end
  end

  describe "verify/2" do
    test "reads the file and hashes its exact bytes" do
      dir = Path.join(System.tmp_dir!(), "verify-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      path = write_memory!(dir, "plain.md", "user", "No pointers here.")

      assert {:ok, verdict} = Staleness.verify(path, checkouts: [])
      assert verdict.status == :ok
      assert verdict.content_sha256 == Staleness.content_hash(File.read!(path))
    end

    test "an unreadable path is an error, not a verdict" do
      assert {:error, :enoent} = Staleness.verify("/nonexistent/memory.md", checkouts: [])
    end
  end
end
