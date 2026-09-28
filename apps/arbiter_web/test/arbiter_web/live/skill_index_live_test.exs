defmodule ArbiterWeb.SkillIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Skills

  # The skill list + usage aggregate arrives by `start_async/3` after the
  # connected mount (bd-6xndli); everything but the async tests themselves
  # wants the page once it has landed.
  @async_timeout 5_000

  defp live_skills(conn, path \\ ~p"/skills") do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp new_skill(attrs \\ %{}) do
    base = %{name: "skill-#{System.unique_integer([:positive])}", body: "# body"}
    {:ok, skill} = Skills.create_skill(Map.merge(base, attrs))
    skill
  end

  describe "index" do
    test "lists skills and auto-selects the first one into the detail pane", %{conn: conn} do
      skill = new_skill(%{metadata: %{"description" => "does a thing"}})

      {:ok, _view, html} = live_skills(conn)

      assert html =~ skill.name
      assert html =~ "does a thing"
      assert html =~ ~s(id="skills-list")
      assert html =~ ~s(id="skill-detail")
    end

    test "shows empty state with no skills", %{conn: conn} do
      {:ok, _view, html} = live_skills(conn)
      assert html =~ "No skills yet"
    end

    test "flags a name that collides with a bundled skill", %{conn: conn} do
      new_skill(%{name: "code-review"})

      {:ok, _view, html} = live_skills(conn)

      assert html =~ "Collides with a bundled skill name"
    end

    test "list/detail split view stacks to a single column below the md breakpoint", %{
      conn: conn
    } do
      new_skill()

      {:ok, _view, html} = live_skills(conn)

      assert html =~
               ~r/class="[^"]*\bgrid-cols-1\b[^"]*\bmd:grid-cols-\[minmax\(0,320px\)_minmax\(0,1fr\)\][^"]*"/
    end
  end

  # bd-6xndli: the list + per-skill usage aggregate used to run synchronously
  # in mount, biasing selection on data that may already be stale by the time
  # it rendered. It now arrives by `start_async/3` on the connected mount
  # only.
  describe "the async load" do
    setup do
      :meck.new(ArbiterWeb.SkillIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.SkillIndexLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      test = self()

      :meck.expect(ArbiterWeb.SkillIndexLive, :load_skills, fn ->
        send(test, :skills_read)
        :meck.passthrough([])
      end)

      doc = conn |> get(~p"/skills") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query(~s(#skills-panel[data-state="loading"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("#skills-loading") |> Enum.count() == 1
      refute_received :skills_read
    end

    test "renders a loading skeleton before the async load lands, then the data", %{conn: conn} do
      skill = new_skill(%{metadata: %{"description" => "does a thing"}})

      test = self()

      :meck.expect(ArbiterWeb.SkillIndexLive, :load_skills, fn ->
        result = :meck.passthrough([])
        send(test, {:loading_skills, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_skills_load, self()})
        end

        result
      end)

      {:ok, view, _html} = live(conn, ~p"/skills")
      assert_receive {:loading_skills, loader}

      assert has_element?(view, ~s(#skills-panel[data-state="loading"]))
      assert has_element?(view, "#skills-loading")
      refute has_element?(view, "#skill-detail")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#skills-panel[data-state="loaded"]))
      refute has_element?(view, "#skills-loading")
      assert html =~ skill.name
      refute_received {:unreleased_skills_load, _}
    end

    @tag :capture_log
    test "a failed skill load renders an inline error, and Retry recovers", %{conn: conn} do
      skill = new_skill(%{metadata: %{"description" => "behind-the-error"}})

      :meck.expect(ArbiterWeb.SkillIndexLive, :load_skills, fn ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/skills")
      render_async(view, @async_timeout)

      assert has_element?(view, ~s(#skills-panel[data-state="error"]))
      assert has_element?(view, "#skills-error", "database is locked")
      assert has_element?(view, "#skills-retry")
      refute has_element?(view, "#skills-loading")

      :meck.expect(ArbiterWeb.SkillIndexLive, :load_skills, fn ->
        :meck.passthrough([])
      end)

      view |> element("#skills-retry") |> render_click()
      html = render_async(view, @async_timeout)

      refute has_element?(view, "#skills-error")
      assert has_element?(view, ~s(#skills-panel[data-state="loaded"]))
      assert html =~ skill.name
    end
  end

  describe "detail selection" do
    test "clicking a list item selects it into the detail pane", %{conn: conn} do
      _first = new_skill(%{name: "aaa-skill"})
      second = new_skill(%{name: "zzz-skill", metadata: %{"description" => "second one"}})

      {:ok, view, _html} = live_skills(conn)

      html =
        view
        |> element("#skill-row-#{second.id}")
        |> render_click()

      assert html =~ "second one"
    end

    test "detail pane shows materialized/invoked/invoke-rate/scope and toggles with consequence hints",
         %{conn: conn} do
      skill = new_skill(%{code_only: true})

      {:ok, _view, html} = live_skills(conn)

      assert html =~ "materialized"
      assert html =~ "invoked"
      assert html =~ "invoke rate"
      assert html =~ "scope"
      assert html =~ "feature · bug · chore"
      assert html =~ "Auto-invoke"
      assert html =~ "added to every worker prompt where it applies"
      assert html =~ "Code-producing tasks only"
      assert html =~ "skipped on decision and epic types"
      assert html =~ skill.name
    end

    test "shows the never-invoked EmptyState when invoke count is zero", %{conn: conn} do
      new_skill()

      {:ok, _view, html} = live_skills(conn)

      assert html =~ "This skill has never been invoked. The loop pass will propose retiring it."
      assert html =~ "materialized 0 times, invoked 0"
    end
  end

  describe "toggles write through to the skill record" do
    test "toggling auto-invoke flips activation_mode on the skill", %{conn: conn} do
      skill = new_skill(%{activation_mode: :situational})

      {:ok, view, _html} = live_skills(conn)

      view
      |> element("#toggle-auto-invoke")
      |> render_click()

      render_async(view, @async_timeout)

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.activation_mode == :always_on
    end

    test "toggling code-producing-tasks-only flips code_only on the skill", %{conn: conn} do
      skill = new_skill(%{code_only: false})

      {:ok, view, _html} = live_skills(conn)

      view
      |> element("#toggle-code-only")
      |> render_click()

      render_async(view, @async_timeout)

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.code_only == true
    end
  end

  describe "create" do
    test "creates a skill via the textarea form", %{conn: conn} do
      {:ok, view, _html} = live_skills(conn)

      name = "created-#{System.unique_integer([:positive])}"

      view |> element("button", "New skill") |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "skill" => %{"name" => name, "body" => "# hello", "metadata" => ""}
      })
      |> render_submit()

      html = render_async(view, @async_timeout)

      assert html =~ name
      assert {:ok, _} = Skills.get_skill(name)
    end

    test "surfaces a validation error inline", %{conn: conn} do
      {:ok, view, _html} = live_skills(conn)

      view |> element("button", "New skill") |> render_click()

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "Not Kebab", "body" => "x", "metadata" => ""}
        })
        |> render_submit()

      # Form stays open with an error; the skill was not created.
      assert html =~ "text-error"
      assert Skills.list_skills() == []
    end

    test "warns (does not block) on bundled-name collision via change validation", %{conn: conn} do
      {:ok, view, _html} = live_skills(conn)

      view |> element("button", "New skill") |> render_click()

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "code-review", "body" => "x", "metadata" => ""}
        })
        |> render_change()

      assert html =~ "collides with a bundled skill"
    end
  end

  describe "edit" do
    test "edits the selected skill's body from the detail pane", %{conn: conn} do
      skill = new_skill(%{body: "v1"})

      {:ok, view, _html} = live_skills(conn)

      view |> element("#skill-detail button", "Edit") |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "skill" => %{"name" => skill.name, "body" => "v2-updated", "metadata" => ""}
      })
      |> render_submit()

      render_async(view, @async_timeout)

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.body == "v2-updated"
    end
  end

  describe "delete" do
    test "deletes the selected skill from the detail pane", %{conn: conn} do
      skill = new_skill()

      {:ok, view, _html} = live_skills(conn)

      view
      |> element("#skill-detail button[phx-click=delete][phx-value-id='#{skill.id}']")
      |> render_click()

      render_async(view, @async_timeout)

      assert {:error, :not_found} = Skills.get_skill(skill.id)
    end
  end
end
